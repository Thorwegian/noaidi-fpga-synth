// program_builder.cpp — CSP programs built, checked, scheduled and encoded
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The scheduler keeps a scoreboard: for every register the cycle from
// which it may be read, and the same for the flags and the accumulator
// together. An instruction issues at the first cycle at or after the
// front end's next cycle when everything it reads is ready; the cycles
// it waits become NOP rows before it. A scalar loop's body is laid out
// once for every iteration, so it is scheduled twice — once from the
// loop's entry, once from its own end as the next iteration sees it — and
// takes the larger wait at every instruction, until the layout is stable.
// A vector loop issues each body instruction for a round of elements
// before the next, so an element's dependent instructions are a round
// apart; only a round of fewer elements than the latency needs NOPs.

#include "program_builder.hpp"

#include <algorithm>
#include <functional>
#include <map>

namespace csp {

namespace {

constexpr int64_t never = -1;

bool is_input(int address) {
    return address >= io_base && address < io_base + io_count;
}

bool reads_flags(Op op) {
    return op == Op::sel || op == Op::skip;
}

bool sets_flags(Op op) {
    switch (op) {
    case Op::mac: case Op::macw: case Op::interp: case Op::add3: case Op::cmp: case Op::abs:
    case Op::min: case Op::max: case Op::andxor: case Op::shift:
        return true;
    default:
        return false;
    }
}

bool writes_register(Op op) {
    return sets_flags(op) || op == Op::sel;
}

bool uses_x(Op op) {
    return op != Op::nop && op != Op::skip && op != Op::shift && op != Op::loop && op != Op::vloop;
}

bool uses_y(Op op) {
    return op != Op::nop && op != Op::skip && op != Op::abs && op != Op::loop && op != Op::vloop;
}

// Whether an operation reads R as its A operand.
bool reads_result(Op op, ASource a) {
    if (a != ASource::result) return false;
    switch (op) {
    case Op::mac: case Op::macw: case Op::interp: case Op::add3: case Op::andxor: case Op::shift:
        return true;
    default:
        return false;
    }
}

bool reads_accumulator(Op op, ASource a) {
    if (a != ASource::accumulator) return false;
    return reads_result(op, ASource::result) || op == Op::acc;
}

} // namespace

// ---- emitting -----------------------------------------------------------------

void ProgramBuilder::issue(std::string message, bool error) {
    issues_.push_back({instructions_.size(), error, std::move(message)});
}

void ProgramBuilder::check_operand(const Operand &operand, bool wide, bool result) {
    switch (operand.mode) {
    case Operand::Mode::direct:
        if (operand.value < 0 || operand.value >= direct_reach) {
            issue("a direct operand reaches 0–1023: " + std::to_string(operand.value));
        } else if (wide && operand.value % 2 != 0) {
            issue("a wide operand needs an even register: " + std::to_string(operand.value));
        } else if (result && is_input(operand.value)) {
            issue("a result cannot go to an input register");
        }
        break;
    case Operand::Mode::i:
    case Operand::Mode::j:
        if (operand.value < 0 || operand.value > 0x3FF) {
            issue("an offset is 0–1023: " + std::to_string(operand.value));
        } else if (wide && operand.value % 2 != 0) {
            issue("a wide operand needs an even offset: " + std::to_string(operand.value));
        }
        break;
    case Operand::Mode::immediate:
        break;
    }
}

size_t ProgramBuilder::emit(Entry entry) {
    instructions_.push_back(entry);
    return instructions_.size() - 1;
}

size_t ProgramBuilder::arithmetic(Op op, Operand r, ASource a, Source x, Source y, bool wide) {
    if (wide && a != ASource::result) {
        issue(std::string(mnemonic(op)) + ".w works in place: A is R");
    }
    if (x.operand.mode == Operand::Mode::immediate && y.operand.mode == Operand::Mode::immediate
        && x.immediate != y.immediate) {
        issue("one immediate a word: X and Y cannot both be immediates");
    }
    check_operand(r, wide, true);
    check_operand(x.operand, false, false);
    check_operand(y.operand, wide && op != Op::shift, false);
    Entry entry;
    entry.op        = op;
    entry.wide      = wide;
    entry.a_source  = a;
    entry.r         = r;
    entry.x         = x.operand;
    entry.y         = y.operand;
    entry.immediate = x.operand.mode == Operand::Mode::immediate ? x.immediate : y.immediate;
    return emit(entry);
}

size_t ProgramBuilder::nop() {
    return emit(Entry{});
}

size_t ProgramBuilder::mac(Operand r, ASource a, Source x, Source y, bool wide) {
    return arithmetic(Op::mac, r, a, x, y, wide);
}
size_t ProgramBuilder::macw(Operand r, ASource a, Source x, Source y, bool wide) {
    return arithmetic(Op::macw, r, a, x, y, wide);
}
size_t ProgramBuilder::interp(Operand r, ASource a, Source x, Source y, bool wide) {
    return arithmetic(Op::interp, r, a, x, y, wide);
}
size_t ProgramBuilder::add3(Operand r, ASource a, Source x, Source y, bool wide) {
    return arithmetic(Op::add3, r, a, x, y, wide);
}
size_t ProgramBuilder::andxor(Operand r, ASource a, Source x, Source y) {
    return arithmetic(Op::andxor, r, a, x, y, false);
}
size_t ProgramBuilder::shift(Operand r, ASource a, Source y, bool wide) {
    return arithmetic(Op::shift, r, a, Source::reg(Operand::direct(0)), y, wide);
}
size_t ProgramBuilder::acc(ASource a, Source x, Source y) {
    if (a == ASource::result) {
        issue("ACC's A operand is 0 or acc");
    }
    return arithmetic(Op::acc, Operand::none(), a, x, y, false);
}
size_t ProgramBuilder::sel(Operand r, Condition cond, Source x, Source y) {
    const size_t at = arithmetic(Op::sel, r, ASource::zero, x, y, false);
    instructions_[at].cond = cond;
    return at;
}
size_t ProgramBuilder::cmp(Operand r, Source x, Source y) {
    return arithmetic(Op::cmp, r, ASource::zero, x, y, false);
}
size_t ProgramBuilder::min(Operand r, Source x, Source y) {
    return arithmetic(Op::min, r, ASource::zero, x, y, false);
}
size_t ProgramBuilder::max(Operand r, Source x, Source y) {
    return arithmetic(Op::max, r, ASource::zero, x, y, false);
}
size_t ProgramBuilder::abs(Operand r, Source x) {
    return arithmetic(Op::abs, r, ASource::zero, x, Source::reg(Operand::direct(0)), false);
}

size_t ProgramBuilder::idx(IndexRegister which, Source x, Source y) {
    const size_t at         = arithmetic(Op::idx, Operand::none(), ASource::zero, x, y, false);
    instructions_[at].which = which;
    return at;
}

size_t ProgramBuilder::open_loop(IndexRegister which, int count, int stride, bool vector) {
    if (count < 0 || count > loop_count_max) {
        issue("a loop's count is 0–1023: " + std::to_string(count));
    }
    if (stride < -loop_stride_max - 1 || stride > loop_stride_max) {
        issue("a loop's stride is a signed ten-bit number: " + std::to_string(stride));
    }
    Entry entry;
    entry.op        = vector ? Op::vloop : Op::loop;
    entry.which     = which;
    entry.count     = count;
    entry.immediate = stride;
    entry.open      = true;
    return emit(entry);
}

size_t ProgramBuilder::loop(IndexRegister which, size_t length, int count, int stride, bool vector) {
    const size_t at = open_loop(which, count, stride, vector);
    close_loop(at, at + 1 + length);
    return at;
}

void ProgramBuilder::close_loop(size_t at) {
    close_loop(at, instructions_.size());
}

void ProgramBuilder::close_loop(size_t at, size_t end) {
    if (at >= instructions_.size() || (instructions_[at].op != Op::loop && instructions_[at].op != Op::vloop)) {
        issue("close_loop at a position that is not a LOOP");
        return;
    }
    instructions_[at].end  = end;
    instructions_[at].open = false;
}

size_t ProgramBuilder::open_skip(Condition cond) {
    Entry entry;
    entry.op   = Op::skip;
    entry.cond = cond;
    entry.open = true;
    return emit(entry);
}

size_t ProgramBuilder::skip(Condition cond, size_t count) {
    const size_t at = open_skip(cond);
    close_skip(at, at + 1 + count);
    return at;
}

void ProgramBuilder::close_skip(size_t at) {
    close_skip(at, instructions_.size());
}

void ProgramBuilder::close_skip(size_t at, size_t end) {
    if (at >= instructions_.size() || instructions_[at].op != Op::skip) {
        issue("close_skip at a position that is not a SKIP");
        return;
    }
    instructions_[at].end  = end;
    instructions_[at].open = false;
}

// ---- building: checks, the schedule, the rows ----------------------------------------

namespace {

// The scoreboard: when each register, and the flags with the accumulator,
// may next be read, as absolute cycles.
struct Board {
    std::vector<int64_t> ready;      // a register's ready cycle
    int64_t state   = 0;             // the flags and the accumulator
    int64_t unknown = 0;             // the latest write whose address is not known

    Board() : ready(register_count, 0) {}

    void shift(int64_t delta) {
        for (int64_t &cycle : ready) cycle += delta;
        state += delta;
        unknown += delta;
    }
    void merge(const Board &other) {
        for (size_t i = 0; i < ready.size(); ++i) ready[i] = std::max(ready[i], other.ready[i]);
        state   = std::max(state, other.state);
        unknown = std::max(unknown, other.unknown);
    }
};

// What an index register is known to hold: an address, when it was set
// from an immediate alone; otherwise anything.
struct IndexState {
    bool known_base = false;
    int base        = 0;
};

// The addresses an operand may name, as the scheduler sees them.
struct Access {
    bool any = false;                 // nothing is known: every register
    std::vector<int> addresses;       // else these (a pair's second is added by the caller)
};

Access access_of(const Operand &operand, const IndexState (&index)[2]) {
    Access access;
    if (operand.mode == Operand::Mode::direct) {
        access.addresses.push_back(operand.value);
        return access;
    }
    if (operand.mode == Operand::Mode::immediate) {
        return access;                                  // nothing read from DMEM
    }
    const IndexState &state = index[operand.mode == Operand::Mode::j ? 1 : 0];
    if (state.known_base) {
        access.addresses.push_back((state.base | operand.value) & (address_space - 1));
    } else {
        access.any = true;
    }
    return access;
}

// A placed instruction: the emitted entry's index, or a NOP.
struct Placed {
    size_t source;            // index into the builder's instructions; SIZE_MAX for a wait NOP
    bool wait = false;
};

constexpr size_t wait_nop = static_cast<size_t>(-1);

} // namespace

ProgramBuilder::Built ProgramBuilder::build() const {
    Built built;
    built.issues = issues_;

    // ---- the whole-program checks ----
    std::vector<size_t> loop_end(instructions_.size(), 0);
    for (size_t at = 0; at < instructions_.size(); ++at) {
        const Entry &entry = instructions_[at];
        if (entry.open) {
            built.issues.push_back({at, true, std::string(mnemonic(entry.op)) + " never closed"});
        }
        if ((entry.op == Op::loop || entry.op == Op::vloop)) {
            if (entry.end <= at + 1) {
                built.issues.push_back({at, true, "LOOP with an empty body"});
            } else if (entry.end > instructions_.size()) {
                built.issues.push_back({at, true, "LOOP past the program's end"});
            }
            loop_end[at] = entry.end;
        }
        if (entry.op == Op::skip && entry.end > instructions_.size()) {
            built.issues.push_back({at, true, "SKIP past the program's end"});
        }
        if (entry.op == Op::skip) {
            for (size_t inner = at + 1; inner < entry.end && inner < instructions_.size(); ++inner) {
                const Op op = instructions_[inner].op;
                if (op == Op::loop || op == Op::vloop) {
                    built.issues.push_back({at, true, "a SKIP does not cross a LOOP"});
                    break;
                }
            }
            // nor the end of the loop it is in: the repeat discards the rows behind the loop's
            // last, which would take the skipped count with them
            for (size_t outer_at = 0; outer_at < at; ++outer_at) {
                const Entry &outer = instructions_[outer_at];
                if ((outer.op == Op::loop || outer.op == Op::vloop) && at < outer.end && entry.end > outer.end) {
                    built.issues.push_back({at, true, "a SKIP does not cross the end of its loop"});
                    break;
                }
            }
        }
    }
    // Nesting: at most two, on different index registers, the inner inside the
    // outer; a vector body holds no loop, no SKIP, no ACC and no accumulator.
    for (size_t at = 0; at < instructions_.size(); ++at) {
        const Entry &outer = instructions_[at];
        if (outer.op != Op::loop && outer.op != Op::vloop) continue;
        for (size_t inner_at = at + 1; inner_at < outer.end && inner_at < instructions_.size(); ++inner_at) {
            const Entry &inner = instructions_[inner_at];
            if (outer.op == Op::vloop) {
                if (inner.op == Op::loop || inner.op == Op::vloop || inner.op == Op::skip || inner.op == Op::acc
                    || inner.a_source == ASource::accumulator) {
                    built.issues.push_back({inner_at, true, "a vector body holds no loop, SKIP, ACC or acc operand"});
                }
                if (inner.op == Op::idx && inner.which == outer.which) {
                    built.issues.push_back({inner_at, true, "a vector body cannot set the loop's own index register"});
                }
            } else if (inner.op == Op::idx && inner.which == outer.which) {
                built.issues.push_back({inner_at, true, "a loop body cannot set the loop's own index register"});
            } else if (inner.op == Op::loop || inner.op == Op::vloop) {
                if (inner.which == outer.which) {
                    built.issues.push_back({inner_at, true, "nested loops need different index registers"});
                }
                if (inner.end > outer.end) {
                    built.issues.push_back({inner_at, true, "an inner loop ends past its outer loop"});
                }
                for (size_t third = inner_at + 1; third < inner.end && third < instructions_.size(); ++third) {
                    if (instructions_[third].op == Op::loop || instructions_[third].op == Op::vloop) {
                        built.issues.push_back({third, true, "loops nest one level"});
                    }
                }
            }
        }
    }
    for (const BuildIssue &found : built.issues) {
        if (found.error) built.ok = false;
    }
    if (!built.ok) {
        return built;
    }

    // ---- the schedule ----
    // The program as placed: the entries in order, NOP rows before an
    // instruction that would otherwise read what is not yet written.
    std::vector<Placed> placed;
    std::vector<int64_t> issue_cycle(instructions_.size(), 0);
    IndexState index[2];
    Board board;

    // The cycle an entry may issue at, given the board, and the board after it.
    auto earliest = [&](const Entry &entry, const Board &at_board, const IndexState (&at_index)[2],
                        int64_t not_before) -> int64_t {
        int64_t cycle = not_before;
        auto wait_for = [&](const Access &access, bool pair) {
            if (access.any) {
                for (const int64_t ready : at_board.ready) cycle = std::max(cycle, ready);
                cycle = std::max(cycle, at_board.unknown);
                return;
            }
            for (const int address : access.addresses) {
                if (address >= 0 && address < register_count) {
                    cycle = std::max(cycle, at_board.ready[static_cast<size_t>(address)]);
                    if (pair && address + 1 < register_count) {
                        cycle = std::max(cycle, at_board.ready[static_cast<size_t>(address + 1)]);
                    }
                }
            }
            if (!access.addresses.empty()) cycle = std::max(cycle, at_board.unknown);
        };
        if (reads_result(entry.op, entry.a_source)) wait_for(access_of(entry.r, at_index), entry.wide);
        if (uses_x(entry.op)) wait_for(access_of(entry.x, at_index), false);
        if (uses_y(entry.op)) wait_for(access_of(entry.y, at_index), entry.wide && entry.op != Op::shift);
        if (reads_flags(entry.op) || reads_accumulator(entry.op, entry.a_source)) {
            cycle = std::max(cycle, at_board.state);
        }
        return cycle;
    };

    auto note_writes = [&](const Entry &entry, Board &at_board, IndexState (&at_index)[2], int64_t cycle) {
        if (writes_register(entry.op) && entry.r.mode != Operand::Mode::immediate) {
            const Access access = access_of(entry.r, at_index);
            if (access.any) {
                at_board.unknown = std::max(at_board.unknown, cycle + result_latency);
            }
            for (const int address : access.addresses) {
                if (address > 0 && address < register_count) {
                    at_board.ready[static_cast<size_t>(address)] = cycle + result_latency;
                    if (entry.wide && address + 1 < register_count) {
                        at_board.ready[static_cast<size_t>(address + 1)] = cycle + result_latency;
                    }
                }
            }
        }
        if (sets_flags(entry.op) || entry.op == Op::acc) {
            at_board.state = std::max(at_board.state, cycle + state_latency);
        }
        if (entry.op == Op::idx) {
            IndexState &state = at_index[entry.which == IndexRegister::j ? 1 : 0];
            state.known_base  = false;
            if (entry.x.mode == Operand::Mode::immediate && entry.y.mode == Operand::Mode::direct
                && entry.y.value == 0) {
                state.known_base = true;
                state.base       = entry.immediate & (address_space - 1);
            }
        }
    };

    // Place a range [from, to) of entries: scalar code with loops inside.
    // Returns the cycle after the last issue. `minimum_wait[at]` is the
    // least number of NOPs before entry `at`, from an earlier pass over a
    // loop body.
    std::vector<int> minimum_wait(instructions_.size(), 0);
    std::vector<int> wait_found(instructions_.size(), 0);
    std::vector<size_t> loop_end_row(instructions_.size(), 0);   // a loop's body end, as a row

    std::function<int64_t(size_t, size_t, Board &, IndexState (&)[2], int64_t, std::vector<Placed> *)> place;
    place = [&](size_t from, size_t to, Board &at_board, IndexState (&at_index)[2], int64_t start,
                std::vector<Placed> *out) -> int64_t {
        int64_t next = start;
        for (size_t at = from; at < to;) {
            const Entry &entry = instructions_[at];
            if ((entry.op == Op::loop || entry.op == Op::vloop) && entry.count == 0) {
                // A loop that runs nothing is not assembled: not its row, not its body, no cost.
                at = entry.end;
                continue;
            }
            if (entry.op == Op::loop) {
                // The LOOP issues when its slot comes; the body follows.
                int64_t cycle = std::max(next, start);
                if (out) out->push_back({at});
                issue_cycle[at] = cycle;
                // Lay the body out: schedule it from the entry, then again
                // from its own end, until the waits are stable.
                const int count = std::max(entry.count, 1);
                Board body_board = at_board;
                IndexState body_index[2] = {at_index[0], at_index[1]};
                // the loop's index register walks on from the base it holds
                body_index[entry.which == IndexRegister::j ? 1 : 0].known_base = false;
                int64_t body_start = cycle + 1;
                std::vector<Placed> body;
                int64_t body_end = 0;
                for (int round = 0; round < 4; ++round) {
                    body.clear();
                    Board trial = body_board;
                    IndexState trial_index[2] = {body_index[0], body_index[1]};
                    body_end = place(at + 1, entry.end, trial, trial_index, body_start, &body);
                    // the next iteration sees this one's writes: schedule once more
                    // from the body's end and keep the larger waits
                    Board again = trial;
                    IndexState again_index[2] = {trial_index[0], trial_index[1]};
                    std::vector<int> before = wait_found;
                    place(at + 1, entry.end, again, again_index, body_end + jump_penalty, nullptr);
                    bool grew = false;
                    for (size_t k = at + 1; k < entry.end; ++k) {
                        if (wait_found[k] > minimum_wait[k]) {
                            minimum_wait[k] = wait_found[k];
                            grew = true;
                        }
                    }
                    if (!grew) {
                        body_board = trial;
                        body_index[0] = trial_index[0];
                        body_index[1] = trial_index[1];
                        break;
                    }
                }
                if (out) {
                    // a loop inside the body recorded its end row relative to
                    // the body: the body's rows start here in the image
                    const size_t base = out->size();
                    out->insert(out->end(), body.begin(), body.end());
                    for (size_t k = at + 1; k < entry.end; ++k) {
                        if (instructions_[k].op == Op::loop || instructions_[k].op == Op::vloop) loop_end_row[k] += base;
                    }
                    loop_end_row[at] = out->size();
                }
                // The loop's cost: the body `count` times, a jump between
                // iterations; the board after the last iteration is this one's,
                // shifted to where the last one ends.
                const int64_t body_cycles = body_end - body_start;
                const int64_t last_start  = body_start + (count - 1) * (body_cycles + jump_penalty);
                body_board.shift(last_start - body_start);
                at_board = body_board;
                at_index[0] = body_index[0];
                at_index[1] = body_index[1];
                at_index[entry.which == IndexRegister::j ? 1 : 0].known_base = false;
                next = last_start + body_cycles;
                at   = entry.end;
                continue;
            }
            if (entry.op == Op::vloop) {
                // Each body instruction is issued for every element of a round
                // before the next instruction; an element's dependent instructions
                // are a round apart.
                int64_t cycle = std::max(next, start);
                if (out) out->push_back({at});
                issue_cycle[at] = cycle;
                const int count    = std::max(entry.count, 1);
                const int rounds   = (count + vector_round - 1) / vector_round;
                const int elements = std::min(count, vector_round);
                IndexState body_index[2] = {at_index[0], at_index[1]};
                body_index[entry.which == IndexRegister::j ? 1 : 0].known_base = false;
                // the body's waits, in instructions: a dependent pair needs
                // ceil(latency / elements) instructions between, less one
                std::vector<size_t> body_rows;
                int64_t body_cycle = cycle + 1;          // element 0 of the first row
                Board body_board = at_board;
                // ready cycles inside the body are per row, in units of rows
                std::vector<int64_t> row_of_ready(register_count, never);
                int64_t row_state = never, row_unknown = never;
                int64_t row_index[2] = {never, never};   // the row an IDX set each index register
                int64_t row = 0;
                for (size_t k = at + 1; k < entry.end; ++k) {
                    const Entry &body_entry = instructions_[k];
                    // the earliest row: from before the loop, and from earlier rows
                    int64_t earliest_cycle = earliest(body_entry, body_board, body_index, body_cycle);
                    int64_t need_row = row;
                    if (earliest_cycle > body_cycle + row * elements) {
                        need_row = std::max(need_row, (earliest_cycle - body_cycle + elements - 1) / elements);
                    }
                    auto row_wait = [&](const Access &access, bool pair) {
                        auto need = [&](int64_t written_row) {
                            if (written_row == never) return;
                            const int64_t spacing = (result_latency + elements - 1) / elements;
                            need_row = std::max(need_row, written_row + spacing);
                        };
                        if (access.any) {
                            for (const int64_t written : row_of_ready) need(written);
                            need(row_unknown);
                            return;
                        }
                        for (const int address : access.addresses) {
                            if (address >= 0 && address < register_count) {
                                need(row_of_ready[static_cast<size_t>(address)]);
                                if (pair && address + 1 < register_count) need(row_of_ready[static_cast<size_t>(address + 1)]);
                            }
                        }
                        if (!access.addresses.empty()) need(row_unknown);
                    };
                    if (reads_result(body_entry.op, body_entry.a_source)) row_wait(access_of(body_entry.r, body_index), body_entry.wide);
                    if (uses_x(body_entry.op)) row_wait(access_of(body_entry.x, body_index), false);
                    if (uses_y(body_entry.op)) row_wait(access_of(body_entry.y, body_index), body_entry.wide && body_entry.op != Op::shift);
                    if (reads_flags(body_entry.op) && row_state != never) {
                        need_row = std::max(need_row, row_state + (state_latency + elements - 1) / elements);
                    }
                    // an element's private index lands index_latency cycles after
                    // its IDX: the rows that use it come that many elements later
                    for (const Operand *operand : {&body_entry.r, &body_entry.x, &body_entry.y}) {
                        if (!operand->is_indexed()) continue;
                        const int64_t set_row = row_index[operand->index() == IndexRegister::j ? 1 : 0];
                        if (set_row != never) {
                            need_row = std::max(need_row, set_row + (index_latency + elements - 1) / elements);
                        }
                    }
                    const int waits = static_cast<int>(need_row - row);
                    wait_found[k] = waits;
                    for (int w = 0; w < waits; ++w) {
                        if (out) out->push_back({wait_nop, true});
                        body_rows.push_back(wait_nop);
                        ++row;
                    }
                    if (out) out->push_back({k});
                    body_rows.push_back(k);
                    issue_cycle[k] = body_cycle + row * elements;
                    // this row's writes
                    if (writes_register(body_entry.op) && body_entry.r.mode != Operand::Mode::immediate) {
                        const Access access = access_of(body_entry.r, body_index);
                        if (access.any) row_unknown = row;
                        for (const int address : access.addresses) {
                            if (address > 0 && address < register_count) {
                                row_of_ready[static_cast<size_t>(address)] = row;
                                if (body_entry.wide && address + 1 < register_count) row_of_ready[static_cast<size_t>(address + 1)] = row;
                            }
                        }
                    }
                    if (sets_flags(body_entry.op)) row_state = row;
                    if (body_entry.op == Op::idx) {
                        body_index[body_entry.which == IndexRegister::j ? 1 : 0].known_base = false;
                        row_index[body_entry.which == IndexRegister::j ? 1 : 0]            = row;
                    }
                    ++row;
                }
                if (out) loop_end_row[at] = out->size();
                // the loop's cycles: every row for every round
                const int64_t rows = row;
                int64_t end_cycle = body_cycle;
                for (int r = 0; r < rounds; ++r) {
                    const int in_round = std::min(count - r * vector_round, vector_round);
                    end_cycle += rows * in_round;
                }
                // what the body wrote, ready after its last element
                for (size_t k = at + 1; k < entry.end; ++k) {
                    const Entry &body_entry = instructions_[k];
                    note_writes(body_entry, at_board, body_index, end_cycle - 1);
                }
                at_index[0] = body_index[0];
                at_index[1] = body_index[1];
                at_index[entry.which == IndexRegister::j ? 1 : 0].known_base = false;
                next = end_cycle + index_latency - 1;
                at   = entry.end;
                continue;
            }

            // A scalar instruction: wait for its operands, then issue.
            const int64_t cycle = std::max(earliest(entry, at_board, at_index, next), next + minimum_wait[at]);
            const int waits = static_cast<int>(cycle - next);
            wait_found[at] = waits;
            if (out) {
                for (int w = 0; w < waits; ++w) out->push_back({wait_nop, true});
                out->push_back({at});
                // the chip has no stall: the index lands index_latency cycles after the
                // IDX issues, so the rows between are NOPs the program carries
                if (entry.op == Op::idx) {
                    for (int w = 1; w < index_latency; ++w) out->push_back({wait_nop, true});
                }
            }
            issue_cycle[at] = cycle;
            note_writes(entry, at_board, at_index, cycle);
            next = cycle + (entry.op == Op::idx ? index_latency : 1);
            ++at;
        }
        return next;
    };

    const int64_t cycles = place(0, instructions_.size(), board, index, 0, &placed);
    built.cycles = static_cast<int>(cycles);
    if (cycles > pass_cycle_limit) {
        built.issues.push_back({instructions_.size(), true,
                                "the pass runs " + std::to_string(cycles) + " cycles, the limit is "
                                        + std::to_string(pass_cycle_limit)});
        built.ok = false;
    }
    if (placed.size() > static_cast<size_t>(program_rows)) {
        built.issues.push_back({instructions_.size(), true,
                                "the program has " + std::to_string(placed.size()) + " rows, IMEM holds "
                                        + std::to_string(program_rows)});
        built.ok = false;
    }
    if (!built.ok) {
        return built;
    }

    // ---- the rows and the ROM ----
    constexpr size_t omitted = static_cast<size_t>(-1);
    built.position.assign(instructions_.size(), omitted);   // a loop of count 0 and its body have no row
    for (size_t row = 0; row < placed.size(); ++row) {
        if (placed[row].source != wait_nop) built.position[placed[row].source] = row;
    }
    // the first placed row at or after each instruction (a SKIP may end where a loop was omitted)
    std::vector<size_t> first_row(instructions_.size() + 1, placed.size());
    for (size_t at = instructions_.size(); at-- > 0;) {
        first_row[at] = built.position[at] != omitted ? built.position[at] : first_row[at + 1];
    }
    std::map<uint32_t, uint16_t> rom_index;
    rom_index[0] = 0;
    auto rom_row = [&](const Control &control) -> uint16_t {
        const uint32_t bits = control.encode();
        const auto found    = rom_index.find(bits);
        if (found != rom_index.end()) return found->second;
        if (built.image.rom_used >= op_count) {
            built.issues.push_back({0, true, "the decode ROM is full"});
            built.ok = false;
            return 0;
        }
        const uint16_t row = static_cast<uint16_t>(built.image.rom_used++);
        built.image.rom[row] = bits;
        rom_index[bits]      = row;
        return row;
    };
    for (size_t row = 0; row < placed.size(); ++row) {
        if (placed[row].source == wait_nop) continue;
        const Entry &entry = instructions_[placed[row].source];
        Control control    = control_of(entry.op, entry.wide, entry.a_source);
        Word word;
        switch (entry.op) {
        case Op::nop:
            break;
        case Op::loop:
        case Op::vloop:
            control.sub = static_cast<uint8_t>((entry.op == Op::vloop ? 2 : 0) | (entry.which == IndexRegister::j ? 1 : 0));
            word.x      = Operand{Operand::Mode::immediate, entry.count & 0x3FF};
            word.y      = Operand{Operand::Mode::immediate, entry.immediate & 0x3FF};
            word.imm    = static_cast<uint32_t>(loop_end_row[placed[row].source]);
            break;
        case Op::skip: {
            word.cond = static_cast<uint8_t>(entry.cond);
            const size_t end_row = first_row[std::min(entry.end, instructions_.size())];
            word.imm = static_cast<uint32_t>(end_row - row - 1);   // the rows skipped
            break;
        }
        case Op::idx:
            control.writes = entry.which == IndexRegister::j ? Writes::index_j : Writes::index_i;
            control.sub    = entry.which == IndexRegister::j ? 1 : 0;
            word.x         = entry.x;
            word.y         = entry.y;
            word.imm       = static_cast<uint32_t>(entry.immediate & 0x3FFFF);
            break;
        default:
            word.r    = entry.r;
            word.x    = entry.x;
            word.y    = entry.y;
            word.cond = static_cast<uint8_t>(entry.cond);
            word.imm  = static_cast<uint32_t>(entry.immediate & 0x3FFFF);
            break;
        }
        word.op = rom_row(control);
        built.image.rows[row] = word.encode();
    }
    built.image.length = static_cast<int>(placed.size());
    return built;
}

} // namespace csp
