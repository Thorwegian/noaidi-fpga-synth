// processor.cpp — the CSP reference model (see processor.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Arithmetic happens in the accumulator's format, Q8.46, in a 128-bit
// integer so nothing overflows on the way: a word enters shifted left by
// 32, a wide value by 14, a word × word product by 18, and a word × wide
// product as it is. Results are truncated (an arithmetic shift right, so
// toward minus infinity) and then saturated or wrapped to the destination
// (docs/csp2_isa.md; the first revision's arithmetic, kept).

#include "processor.hpp"

#include <algorithm>
#include <cstdio>
#include <iterator>
#include <string>

namespace csp {

namespace {

using Wide = __int128;

constexpr int word_to_accumulator = accumulator_fraction_bits - word_fraction_bits;
constexpr int wide_to_accumulator = accumulator_fraction_bits - wide_fraction_bits;
constexpr int max_shift           = 63;

struct Reduced {
    int64_t value;
    bool overflow;
};

Reduced saturate(Wide value, int bits) {
    if (value > largest(bits)) return {largest(bits), true};
    if (value < smallest(bits)) return {smallest(bits), true};
    return {static_cast<int64_t>(value), false};
}

int64_t wrap(Wide value, int bits) {
    return sign_extend(static_cast<int64_t>(value), bits);
}

Wide from_word(int64_t word) {
    return Wide{word} << word_to_accumulator;
}

Wide from_wide(int64_t wide) {
    return Wide{wide} << wide_to_accumulator;
}

// A product in the accumulator's format: word × word, or word × wide.
Wide product(int64_t x_word, int64_t y, bool y_is_wide) {
    const Wide raw = Wide{x_word} * Wide{y};
    return y_is_wide ? raw : raw << (word_to_accumulator - word_fraction_bits);
}

Wide shift_by(Wide value, int64_t count) {
    count = std::clamp<int64_t>(count, -max_shift, max_shift);
    return count >= 0 ? value * (Wide{1} << count) : value >> -count;
}

bool is_input(int address) {
    return address >= io_base && address < io_base + io_count;
}

bool is_sink(int address) {
    return address >= sink_base && address < sink_base + sink_count;
}

std::string hex(int address) {
    char text[16];
    std::snprintf(text, sizeof text, "0x%03x", address);
    return text;
}

// The operation a control word names.
Op op_of(const Control &control) {
    switch (control.unit) {
    case Unit::none:
        return Op::nop;
    case Unit::multiply_add:
        switch (static_cast<MultiplyAddOp>(control.sub)) {
        case MultiplyAddOp::mac:
            return control.writes == Writes::accumulator ? Op::acc : (control.wrap ? Op::macw : Op::mac);
        case MultiplyAddOp::interp: return Op::interp;
        case MultiplyAddOp::add3: return Op::add3;
        case MultiplyAddOp::cmp: return Op::cmp;
        case MultiplyAddOp::abs: return Op::abs;
        }
        return Op::nop;
    case Unit::logic:
        switch (static_cast<LogicOp>(control.sub)) {
        case LogicOp::min: return Op::min;
        case LogicOp::max: return Op::max;
        case LogicOp::sel: return Op::sel;
        case LogicOp::andxor: return Op::andxor;
        }
        return Op::nop;
    case Unit::shift: return Op::shift;
    case Unit::loop: return (control.sub & 2) ? Op::vloop : Op::loop;
    case Unit::skip: return Op::skip;
    case Unit::index: return Op::idx;
    }
    return Op::nop;
}

bool condition_holds(Condition condition, const Flags &flags) {
    switch (condition) {
    case Condition::always: return true;
    case Condition::negative: return flags.negative;
    case Condition::positive: return !flags.negative;
    case Condition::zero: return flags.zero;
    case Condition::nonzero: return !flags.zero;
    case Condition::overflow: return flags.overflow;
    }
    return false;
}

} // namespace

Processor::Processor() = default;   // the pass counter's register is 0 after reset, as the chip's, until a running pass writes the next pass's number

// ---- firmware side --------------------------------------------------------

void Processor::hold() {
    held_ = true;
}

void Processor::release() {
    held_ = false;
}

bool Processor::load(const Image &image) {
    if (!held_) return false;
    image_ = image;
    return true;
}

void Processor::write(int address, int32_t raw) {
    queue_.push_back({address, static_cast<int32_t>(sign_extend(raw, word_bits)), false});
}

void Processor::write_wide(int address, int64_t raw) {
    const int64_t value = sign_extend(raw, wide_bits);
    write(address, static_cast<int32_t>(value >> word_bits));
    write(address + 1, static_cast<int32_t>(sign_extend(value, word_bits)));
}

void Processor::swap() {
    for (QueuedWrite &queued : queue_) queued.committed = true;
}

void Processor::set_input(int address, int32_t raw) {
    if (is_input(address)) registers_[address] = static_cast<int32_t>(sign_extend(raw, word_bits));
}

int Processor::apply_window(int limit) {
    int applied = 0;
    while (applied < limit && !queue_.empty() && queue_.front().committed) {
        const QueuedWrite queued = queue_.front();
        queue_.pop_front();
        if (queued.address > 0 && queued.address < register_count && !is_input(queued.address)) {
            registers_[queued.address] = queued.raw;
        } else if (is_sink(queued.address)) {
            // the firmware's sink words: into both pages, so that a flip keeps them (#236)
            sink_pages_[0][queued.address - sink_base] = queued.raw;
            sink_pages_[1][queued.address - sink_base] = queued.raw;
        }
        ++applied;
    }
    return applied;
}

// ---- observation ----------------------------------------------------------

int32_t Processor::read(int address) const {
    return address > 0 && address < register_count ? registers_[address] : 0;
}

int64_t Processor::read_wide(int address) const {
    const int64_t upper = read(address);
    const int64_t lower = read(address + 1) & ((int64_t{1} << word_bits) - 1);
    return sign_extend((upper << word_bits) | lower, wide_bits);
}

int32_t Processor::sink(int offset) const {
    return sink_pages_[active_page_][offset];
}

int Processor::index(IndexRegister which) const {
    return index_[static_cast<size_t>(which)];
}

// ---- decode and operands ----------------------------------------------------

Processor::Decoded Processor::decode(size_t row) const {
    Decoded decoded;
    decoded.word    = Word::decode(image_.rows[row]);
    decoded.control = Control::decode(image_.rom[decoded.word.op & 0x3FF]);
    decoded.op      = op_of(decoded.control);
    return decoded;
}

// The address an operand names: the index's bits beside the offset's.
int Processor::resolve(const Operand &operand) const {
    switch (operand.mode) {
    case Operand::Mode::direct: return operand.value;
    case Operand::Mode::i: return (index_[0] | operand.value) & (address_space - 1);
    case Operand::Mode::j: return (index_[1] | operand.value) & (address_space - 1);
    case Operand::Mode::immediate: return -1;
    }
    return -1;
}

// The address an operand names, checked: the index register is ready (an
// IDX's index lands index_latency cycles after its issue, which the front
// end waits for in scalar code and the schedule spaces in a vector body),
// and the offset's bits sit beside the index's, so that the OR the chip
// does is the sum the program meant.
int Processor::resolve_checked(const Operand &operand, PassState &state) const {
    if (operand.is_indexed()) {
        const auto which  = static_cast<size_t>(operand.index());
        const char letter = which == 1 ? 'j' : 'i';
        if (state.scoreboard.index_ready[which] > state.cycle) {
            state.report.errors.push_back("row " + std::to_string(state.pc) + " at cycle " + std::to_string(state.cycle)
                                          + " reads index " + letter + ", ready at "
                                          + std::to_string(state.scoreboard.index_ready[which]));
        }
        if ((index_[which] & operand.value) != 0) {
            state.report.errors.push_back("row " + std::to_string(state.pc) + ": [" + letter + "+"
                                          + std::to_string(operand.value) + "] with " + letter + " = " + hex(index_[which])
                                          + ": the offset's bits overlap the index's");
        }
    }
    return resolve(operand);
}

void Processor::check_ready(int address, bool wide, PassState &state) const {
    for (int reg = address; reg < address + (wide ? 2 : 1); ++reg) {
        if (reg > 0 && reg < register_count && state.scoreboard.register_ready[reg] > state.cycle) {
            char text[96];
            std::snprintf(text, sizeof text, "row %zu at cycle %lld reads register 0x%03x, ready at %lld",
                          state.pc, static_cast<long long>(state.cycle), reg,
                          static_cast<long long>(state.scoreboard.register_ready[reg]));
            state.report.errors.push_back(text);
        }
    }
}

int32_t Processor::read_operand(const Operand &operand, int32_t immediate, PassState &state, bool check) {
    if (operand.mode == Operand::Mode::immediate) return immediate;
    const int address = resolve_checked(operand, state);
    if (address >= register_count) {
        state.report.errors.push_back("read from " + hex(address) + ", outside the register file");
        return 0;
    }
    if (check) check_ready(address, false, state);
    note_access(address, false, state);
    return read(address);
}

int64_t Processor::read_wide_operand(const Operand &operand, PassState &state) {
    const int address = resolve_checked(operand, state);
    if (address < 0 || address % 2 != 0 || address + 1 >= register_count) {
        state.report.errors.push_back("wide read from " + hex(address) + ", not an even register");
        return 0;
    }
    check_ready(address, true, state);
    note_access(address, false, state);
    note_access(address + 1, false, state);
    return read_wide(address);
}

void Processor::write_operand(const Operand &operand, int32_t raw, PassState &state) {
    if (operand.mode == Operand::Mode::immediate) return;   // no result
    const int address = resolve_checked(operand, state);
    if (address == 0) return;
    if (is_input(address)) {
        state.report.errors.push_back("write to input " + hex(address));
        return;
    }
    if (address < register_count) {
        note_access(address, true, state);
        registers_[address] = raw;
        if (trace_) std::fprintf(stderr, "model write %d %d\n", address, raw);
    } else if (is_sink(address)) {
        sink_pages_[1 - active_page_][address - sink_base] = raw;
        if (trace_) std::fprintf(stderr, "model sink %d %d\n", address - sink_base, raw);
        state.sinks_written.insert(address - sink_base);
    } else {
        state.report.errors.push_back("write to " + hex(address) + ", outside registers and sinks");
    }
}

void Processor::write_wide_operand(const Operand &operand, int64_t raw, PassState &state) {
    if (operand.mode == Operand::Mode::immediate) return;
    const int address = resolve_checked(operand, state);
    if (address == 0) return;
    if (address % 2 != 0 || address + 1 >= register_count || is_input(address)) {
        state.report.errors.push_back("wide write to " + hex(address) + ", not an even, writable register");
        return;
    }
    note_access(address, true, state);
    note_access(address + 1, true, state);
    registers_[address]     = static_cast<int32_t>(raw >> word_bits);
    registers_[address + 1] = static_cast<int32_t>(sign_extend(raw, word_bits));
    if (trace_) {
        std::fprintf(stderr, "model write %d %d\nmodel write %d %d\n", address, registers_[address], address + 1,
                     registers_[address + 1]);
    }
}

void Processor::set_flags(int64_t result, bool overflow) {
    flags_ = {result < 0, result == 0, overflow};
}

// What a row writes becomes ready result_latency (or state_latency)
// cycles after its issue.
void Processor::note_writes(const Decoded &decoded, PassState &state) {
    const Control &control = decoded.control;
    if (control.writes == Writes::word || control.writes == Writes::pair) {
        const int address = resolve(decoded.word.r);
        if (address > 0 && address < register_count) {
            state.scoreboard.register_ready[address] = state.cycle + result_latency;
            if (control.writes == Writes::pair && address + 1 < register_count) {
                state.scoreboard.register_ready[address + 1] = state.cycle + result_latency;
            }
        }
    }
    if (control.cond == ConditionKind::flags || control.writes == Writes::accumulator) {
        state.scoreboard.state_ready = state.cycle + state_latency;
    }
    if (control.unit == Unit::index) {
        state.scoreboard.index_ready[control.sub & 1] = state.cycle + index_latency;
    }
}

// Note a register access inside a vector loop: an element must not read a
// register another element writes.
void Processor::note_access(int address, bool write, PassState &state) const {
    if (!state.vector || address <= 0 || address >= register_count) return;
    VectorRun &run = *state.vector;
    if (!write) {
        run.readers[address].insert(run.element);
        return;
    }
    const auto [entry, first] = run.writer.try_emplace(address, run.element);
    if (!first && entry->second != run.element) entry->second = -1;
}

// ---- one row ---------------------------------------------------------------

void Processor::execute(const Decoded &decoded, PassState &state) {
    const Word &word       = decoded.word;
    const Control &control = decoded.control;
    const Op op            = decoded.op;
    const bool is_wide     = control.writes == Writes::pair;
    const auto immediate   = static_cast<int32_t>(sign_extend(word.imm & 0x3FFFF, word_bits));
    const auto condition   = static_cast<Condition>(word.cond);

    // The flags and the accumulator: ready?
    if (control.cond == ConditionKind::select || control.cond == ConditionKind::skip
        || control.a_source == ASource::accumulator) {
        if (state.scoreboard.state_ready > state.cycle) {
            state.report.errors.push_back("row " + std::to_string(state.pc) + " reads the flags or the accumulator "
                                          + std::to_string(state.scoreboard.state_ready - state.cycle)
                                          + " cycles early");
        }
    }

    auto a_value = [&]() -> Wide {
        switch (control.a_source) {
        case ASource::zero: return 0;
        case ASource::result:
            return is_wide ? from_wide(read_wide_operand(word.r, state)) : from_word(read_operand(word.r, 0, state, true));
        case ASource::accumulator: return accumulator_;
        }
        return 0;
    };
    auto x_word = [&]() -> int64_t { return read_operand(word.x, immediate, state, true); };
    auto y_word = [&]() -> int64_t { return read_operand(word.y, immediate, state, true); };
    auto y_raw  = [&]() -> int64_t { return control.y_wide ? read_wide_operand(word.y, state) : y_word(); };
    auto y_value = [&]() -> Wide { return control.y_wide ? from_wide(read_wide_operand(word.y, state)) : from_word(y_word()); };
    auto store = [&](Wide result, bool wraps) {
        const int bits      = is_wide ? wide_bits : word_bits;
        const Wide reduced  = result >> (is_wide ? wide_to_accumulator : word_to_accumulator);
        const Reduced value = wraps ? Reduced{wrap(reduced, bits), false} : saturate(reduced, bits);
        if (is_wide) write_wide_operand(word.r, value.value, state);
        else write_operand(word.r, static_cast<int32_t>(value.value), state);
        set_flags(value.value, value.overflow);
    };
    auto store_word = [&](int64_t raw, bool flags) {
        const auto value = static_cast<int32_t>(sign_extend(raw, word_bits));
        write_operand(word.r, value, state);
        if (flags) set_flags(value, false);
    };

    switch (op) {
    case Op::nop:
        break;
    case Op::mac:
    case Op::macw: {
        const int64_t x = x_word();
        store(a_value() + product(x, y_raw(), control.y_wide), op == Op::macw);
        break;
    }
    case Op::interp: {
        const Wide a        = a_value();
        const int64_t x     = x_word();
        const Reduced delta = saturate((y_value() - a) >> wide_to_accumulator, wide_bits);
        store(a + Wide{delta.value} * x, false);
        break;
    }
    case Op::acc: {
        const int64_t x = x_word();
        const Wide sum  = a_value() + product(x, y_word(), false);
        accumulator_    = saturate(sum, accumulator_bits).value;
        break;
    }
    case Op::add3: {
        const Wide x = from_word(x_word());
        store(a_value() + x + y_value(), false);
        break;
    }
    case Op::sel: {
        const int64_t x = x_word();
        const int64_t y = y_word();
        store_word(condition_holds(condition, flags_) ? y : x, false);
        break;
    }
    case Op::cmp:
        store(from_word(x_word()) - from_word(y_word()), false);
        break;
    case Op::min:
    case Op::max: {
        const int64_t x = x_word();
        const int64_t y = y_word();
        store_word(op == Op::min ? std::min(x, y) : std::max(x, y), true);
        break;
    }
    case Op::andxor: {
        const int64_t a = control.a_source == ASource::zero ? 0 : saturate(a_value() >> word_to_accumulator, word_bits).value;
        const int64_t x = x_word();
        const int64_t y = y_word();
        store_word((x & y) ^ a, true);
        break;
    }
    case Op::shift:
        store(shift_by(a_value(), y_word()), false);
        break;
    case Op::abs: {
        const Wide x = from_word(x_word());
        store(x < 0 ? -x : x, false);
        break;
    }
    case Op::skip:
        if (condition_holds(condition, flags_)) state.skip = static_cast<int>(word.imm & 0x7FF);
        break;
    case Op::idx: {
        const int64_t sum = x_word() + y_word();
        const auto which  = static_cast<size_t>(control.sub & 1);
        index_[which]     = static_cast<int>(((sum % address_space) + address_space) % address_space);
        break;
    }
    case Op::loop: {
        const auto which   = static_cast<IndexRegister>(control.sub & 1);
        const size_t end   = word.imm & 0x7FF;
        const int count    = word.x.value;                       // the ten bits, unsigned
        const int stride   = static_cast<int>(sign_extend(word.y.value, 10));
        const size_t start = state.pc;                           // already past the LOOP row
        if (end <= start) {
            state.report.errors.push_back("LOOP with an empty body");
            break;
        }
        if (count <= 0) {
            state.pc = end;
            break;
        }
        state.loops.push_back({which, start, end, count, stride});
        break;
    }
    case Op::vloop:
        break;   // run by run_vector
    }
}

// A vector loop: the body row by row, each for every element of a round,
// in rounds of sixteen. The loop's index register steps per element; each
// element has its own copy of the other index register and its own flags.
void Processor::run_vector(const Decoded &decoded, size_t at, PassState &state) {
    const Word &word   = decoded.word;
    const auto own     = static_cast<IndexRegister>(decoded.control.sub & 1);
    const auto other   = own == IndexRegister::i ? IndexRegister::j : IndexRegister::i;
    const size_t start = at + 1;
    const size_t end   = word.imm & 0x7FF;
    const int count    = word.x.value;
    const int stride   = static_cast<int>(sign_extend(word.y.value, 10));
    if (end <= start || count <= 0) {
        state.pc = end;
        return;
    }
    struct Element {
        int other_index;
        Flags flags;
        int64_t state_ready;
        int64_t other_index_ready;
    };
    int &own_index   = index_[static_cast<size_t>(own)];
    int &other_index = index_[static_cast<size_t>(other)];
    const int base   = own_index;
    const auto other_slot = static_cast<size_t>(other);
    std::vector<Element> elements(static_cast<size_t>(count),
                                  {other_index, flags_, state.scoreboard.state_ready,
                                   state.scoreboard.index_ready[other_slot]});
    state.vector = VectorRun{other, 0, {}, {}};
    for (int first = 0; first < count && !state.stopped; first += vector_round) {
        const int last = std::min(count, first + vector_round);
        for (size_t row = start; row < end && !state.stopped; ++row) {
            const Decoded body = decode(row);
            for (int element = first; element < last; ++element) {
                Element &mine = elements[static_cast<size_t>(element)];
                own_index     = (base + element * stride) & (address_space - 1);
                other_index   = mine.other_index;
                flags_                                 = mine.flags;
                state.scoreboard.state_ready           = mine.state_ready;
                state.scoreboard.index_ready[other_slot] = mine.other_index_ready;
                state.vector->element = element;
                state.pc              = row;
                if (state.cycle >= pass_cycle_limit) {
                    state.report.errors.push_back("pass longer than " + std::to_string(pass_cycle_limit) + " cycles");
                    state.stopped = true;
                    break;
                }
                if (trace_) {
                    std::fprintf(stderr, "model pc %zu cycle %lld i %d j %d\n", row, static_cast<long long>(state.cycle),
                                 index_[0], index_[1]);
                }
                execute(body, state);
                note_writes(body, state);
                mine = {other_index, flags_, state.scoreboard.state_ready, state.scoreboard.index_ready[other_slot]};
                ++state.cycle;
                // the bubble behind the first row's first element: the chip's front end knows
                // the loop one cycle late and kills the row it fetched meanwhile
                if (first == 0 && row == start && element == 0) ++state.cycle;
            }
        }
    }
    const VectorRun run = *state.vector;
    state.vector.reset();
    for (const auto &[address, writer] : run.writer) {
        const auto readers = run.readers.find(address);
        const bool shared  = readers != run.readers.end()
                            && (writer < 0 || readers->second.size() > 1 || *readers->second.begin() != writer);
        if (shared) {
            char hex[8];
            std::snprintf(hex, sizeof hex, "0x%03x", address);
            state.report.errors.push_back(std::string("vector loop elements share register ") + hex);
        }
    }
    own_index = (base + count * stride) & (address_space - 1);
    if (count > 0) {
        const Element &final = elements.back();
        other_index          = final.other_index;
        flags_               = final.flags;
        // scalar code after the loop sees the last element's state, ready
        // when every element's is
        for (const Element &each : elements) {
            state.scoreboard.state_ready             = std::max(state.scoreboard.state_ready, each.state_ready);
            state.scoreboard.index_ready[other_slot] = std::max(state.scoreboard.index_ready[other_slot],
                                                                each.other_index_ready);
        }
    }
    // nothing to leave: the own index after the loop is in its register for the next row
    state.pc = end;
}

// Loop ends at the current pc: step the index register; repeat the body
// or leave the loop, then the outer loop, which may end at the same place.
void Processor::end_loops(PassState &state) {
    while (!state.loops.empty() && state.pc == state.loops.back().end) {
        Loop &loop = state.loops.back();
        int &value = index_[static_cast<size_t>(loop.index)];
        value      = (value + loop.stride) & (address_space - 1);
        if (--loop.remaining > 0) {
            state.pc = loop.start;
            state.cycle += jump_penalty;
            break;
        }
        state.loops.pop_back();
    }
}

// ---- one pass -------------------------------------------------------------

PassReport Processor::pass() {
    PassState state;
    ++pass_count_;

    if (held_) {
        // a held pass takes the window's 48 writes, as the chip does, and leaves the pass
        // counter's register at the number of the pass after the last one that ran
        state.report.writes_applied = apply_window(write_window);
        active_page_                = 1 - active_page_;
        return state.report;
    }

    const auto length = static_cast<size_t>(image_.length);
    while (state.pc < length && !state.stopped) {
        if (state.cycle >= pass_cycle_limit) {
            state.report.errors.push_back("pass longer than " + std::to_string(pass_cycle_limit) + " cycles");
            state.stopped = true;
            break;
        }
        const Decoded decoded = decode(state.pc);
        if (trace_) {
            std::fprintf(stderr, "model pc %zu cycle %lld i %d j %d\n", state.pc, static_cast<long long>(state.cycle),
                         index_[0], index_[1]);
        }
        const size_t at     = state.pc;
        ++state.pc;
        if (state.skip > 0) {
            --state.skip;
            ++state.cycle;
        } else if (decoded.op == Op::vloop) {
            ++state.cycle;
            run_vector(decoded, at, state);
        } else {
            execute(decoded, state);
            note_writes(decoded, state);
            ++state.cycle;   // an IDX is one cycle: the NOP rows after it carry the wait
        }
        end_loops(state);
    }

    state.report.cycles = static_cast<int>(state.cycle);   // where the next row would issue
    owned_sinks_.insert(state.sinks_written.begin(), state.sinks_written.end());
    std::ranges::set_difference(owned_sinks_, state.sinks_written, std::back_inserter(state.report.stale_sinks));

    state.report.writes_applied = apply_window(write_window);
    active_page_                = 1 - active_page_;
    registers_[io_base]         = static_cast<int32_t>(sign_extend(pass_count_ + 1, word_bits));
    return state.report;
}

} // namespace csp
