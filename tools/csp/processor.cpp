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
// (docs/csp_manual.md section 3).

#include "processor.hpp"

#include <algorithm>
#include <cstdio>
#include <iterator>
#include <string>

namespace csp {

namespace {

using Wide = __int128;

constexpr int word_to_accumulator =
        accumulator_fraction_bits - word_fraction_bits;
constexpr int wide_to_accumulator =
        accumulator_fraction_bits - wide_fraction_bits;
constexpr int max_shift = 63;

struct Reduced {
    int64_t value;
    bool overflow;
};

Reduced saturate(Wide value, int bits) {
    if (value > largest(bits)) {
        return {largest(bits), true};
    }
    if (value < smallest(bits)) {
        return {smallest(bits), true};
    }
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

int modulo_address(int64_t value) {
    const int64_t wrapped = value % address_space;
    return static_cast<int>(wrapped < 0 ? wrapped + address_space : wrapped);
}

bool is_input(int address) {
    return address >= io_base && address < io_base + io_count;
}

bool is_sink(int address) {
    return address >= sink_base && address < sink_base + sink_count;
}

// ---- what the pipeline's interlocks see (rtl/csp/csp_core.sv) ----

// Whether an instruction reads R through its a field.
bool uses_a(Opcode op, ASelect a) {
    const bool reads_r = a == ASelect::result || a == ASelect::wide;
    switch (op) {
    case Opcode::mac:
    case Opcode::macw:
    case Opcode::interp:
    case Opcode::add3:
    case Opcode::andxor:
    case Opcode::shift:
        return reads_r;
    default:
        return false;
    }
}

bool uses_x(Opcode op) {
    return op != Opcode::nop && op != Opcode::skip && op != Opcode::shift;
}

bool uses_y(Opcode op) {
    return op != Opcode::nop && op != Opcode::skip && op != Opcode::abs;
}

bool uses_accumulator(Opcode op, ASelect a) {
    return a == ASelect::accumulator
           && (uses_a(op, ASelect::result) || op == Opcode::acc);
}

bool writes_result(Opcode op) {
    return op != Opcode::nop && op != Opcode::loop && op != Opcode::acc
           && op != Opcode::skip && op != Opcode::idx;
}

bool sets_flags(Opcode op) {
    return writes_result(op) && op != Opcode::sel;
}

// Whether an access names registers: inside the file, a pair at an even
// address.
bool in_registers(int address, bool wide) {
    return address < register_count && !(wide && address % 2 != 0);
}

// The registers an access touches: none, one, or a pair.
std::span<const int> touched(int address, bool wide, std::array<int, 2> &out) {
    if (!in_registers(address, wide)) {
        return {};
    }
    out = {address, address + 1};
    return {out.data(), wide ? 2u : 1u};
}


} // namespace

Processor::Processor() = default;

// ---- firmware side --------------------------------------------------------

void Processor::hold() {
    held_ = true;
}

void Processor::release() {
    held_ = false;
}

bool Processor::load(std::span<const uint64_t> program) {
    if (!held_ || program.size() > max_program_length) {
        return false;
    }
    program_.assign(program.begin(), program.end());
    return true;
}

void Processor::write(int address, int32_t raw) {
    queue_.push_back({address,
                      static_cast<int32_t>(sign_extend(raw, word_bits)),
                      false});
}

void Processor::write_wide(int address, int64_t raw) {
    const int64_t value = sign_extend(raw, wide_bits);
    write(address, static_cast<int32_t>(value >> word_bits));
    write(address + 1, static_cast<int32_t>(sign_extend(value, word_bits)));
}

void Processor::swap() {
    for (QueuedWrite &queued : queue_) {
        queued.committed = true;
    }
}

void Processor::set_input(int address, int32_t raw) {
    if (is_input(address)) {
        registers_[address] = static_cast<int32_t>(sign_extend(raw, word_bits));
    }
}

int Processor::apply_window(int limit) {
    int applied = 0;
    while (applied < limit && !queue_.empty() && queue_.front().committed) {
        const QueuedWrite queued = queue_.front();
        queue_.pop_front();
        const bool writable = queued.address > 0
                              && queued.address < register_count
                              && !is_input(queued.address);
        if (writable) {
            registers_[queued.address] = queued.raw;
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

// ---- operands -------------------------------------------------------------

int Processor::resolve(uint16_t field) const {
    const Operand operand = Operand::decode(field);
    if (operand.mode == Operand::Mode::direct) {
        return operand.value;
    }
    return modulo_address(index(operand.index) + operand.value);
}

int32_t Processor::read_operand(uint16_t field, PassState &state) const {
    const int address = resolve(field);
    if (address >= register_count) {
        state.report.errors.push_back("read from 0x" + std::to_string(address)
                                      + ", outside the register file");
        return 0;
    }
    note_access(address, false, state);
    return read(address);
}

int64_t Processor::read_wide_operand(uint16_t field, PassState &state) const {
    const int address = resolve(field);
    if (address % 2 != 0 || address + 1 >= register_count) {
        state.report.errors.push_back("wide read from 0x"
                                      + std::to_string(address)
                                      + ", not an even register");
        return 0;
    }
    note_access(address, false, state);
    note_access(address + 1, false, state);
    return read_wide(address);
}

void Processor::write_operand(uint16_t field, int32_t raw, PassState &state) {
    const int address = resolve(field);
    if (address == 0) {
        return; // ZERO: the result is discarded
    }
    if (is_input(address)) {
        state.report.errors.push_back("write to input 0x"
                                      + std::to_string(address));
        return;
    }
    if (address < register_count) {
        note_access(address, true, state);
        registers_[address] = raw;
    } else if (is_sink(address)) {
        sink_pages_[1 - active_page_][address - sink_base] = raw;
        state.sinks_written.insert(address - sink_base);
    } else {
        state.report.errors.push_back("write to 0x" + std::to_string(address)
                                      + ", outside registers and sinks");
    }
}

void Processor::write_wide_operand(uint16_t field, int64_t raw,
                                   PassState &state) {
    const int address = resolve(field);
    if (address == 0) {
        return;
    }
    if (address % 2 != 0 || address + 1 >= register_count
        || is_input(address)) {
        state.report.errors.push_back("wide write to 0x"
                                      + std::to_string(address)
                                      + ", not an even, writable register");
        return;
    }
    note_access(address, true, state);
    note_access(address + 1, true, state);
    registers_[address]     = static_cast<int32_t>(raw >> word_bits);
    registers_[address + 1] = static_cast<int32_t>(sign_extend(raw, word_bits));
}

void Processor::set_flags(int64_t result, bool overflow) {
    flags_ = {result < 0, result == 0, overflow};
}

// ---- the pipeline's timing ------------------------------------------------

// The cycle the instruction issues in, after the one before and once
// every value it reads has been written; then what it holds up. As in the
// RTL, this is decided before a skip is known: a skipped instruction
// waits and is waited for all the same.
int64_t Processor::issue(const Instruction &instruction,
                         PassState &state) const {
    Scoreboard &board = state.scoreboard;
    const Opcode op   = instruction.op;
    const bool a_wide = instruction.a == ASelect::wide;
    const bool r_wide = a_wide && has_wide_form(op);
    const bool y_wide = r_wide && op != Opcode::shift;
    const int r       = resolve(instruction.r);
    std::array<int, 2> scratch{};

    int64_t cycle = board.front_ready;
    // In a vector loop, an operand indexed by an element's own copy of an
    // index register waits for that element's IDX.
    auto wait_for_index = [&](uint16_t field) {
        const Operand operand = Operand::decode(field);
        if (state.vector && operand.mode == Operand::Mode::indexed
            && operand.index == state.vector->private_index) {
            cycle = std::max(cycle, board.index_ready);
        }
    };
    auto wait_for = [&](bool reads, int address, bool wide) {
        if (reads) {
            for (const int reg : touched(address, wide, scratch)) {
                cycle = std::max(cycle, board.register_ready[reg]);
            }
        }
    };
    if (uses_a(op, instruction.a)) {
        wait_for_index(instruction.r);
    }
    if (uses_x(op)) {
        wait_for_index(instruction.x);
    }
    if (uses_y(op)) {
        wait_for_index(instruction.y);
    }
    if (writes_result(op)) {
        wait_for_index(instruction.r);
    }
    wait_for(uses_a(op, instruction.a), r, a_wide);
    wait_for(uses_x(op), resolve(instruction.x), false);
    wait_for(uses_y(op), resolve(instruction.y), y_wide);
    if (uses_accumulator(op, instruction.a)) {
        cycle = std::max(cycle, board.accumulator_ready);
    }
    if (op == Opcode::sel || op == Opcode::skip) {
        cycle = std::max(cycle, board.flags_ready);
    }

    const int64_t ready = cycle + result_latency;
    if (writes_result(op) && r != 0 && !is_input(r)) {
        for (const int reg : touched(r, r_wide, scratch)) {
            board.register_ready[reg] = ready;
        }
    }
    if (op == Opcode::acc) {
        board.accumulator_ready = ready;
    }
    if (sets_flags(op)) {
        board.flags_ready = ready;
    }
    // LOOP and IDX hold the front end; in a vector loop, IDX only holds
    // its own element's index register.
    const bool barrier =
            op == Opcode::loop || (op == Opcode::idx && !state.vector);
    if (op == Opcode::idx && state.vector) {
        board.index_ready = cycle + barrier_latency;
    }
    board.front_ready = cycle + (barrier ? barrier_latency : 1);
    return cycle;
}

// Issue an instruction: its cycle, or the end of the pass at the limit.
bool Processor::issue_or_stop(const Instruction &instruction, size_t pc,
                              PassState &state) {
    state.cycle = issue(instruction, state);
    if (state.cycle >= pass_cycle_limit) {
        state.report.errors.push_back("pass longer than "
                                      + std::to_string(pass_cycle_limit)
                                      + " cycles");
        state.stopped = true;
        return false;
    }
    if (trace_) {
        std::fprintf(stderr, "model pc %zu cycle %lld i %d j %d\n", pc,
                     static_cast<long long>(state.cycle), index_[0], index_[1]);
    }
    state.report.cycles = static_cast<int>(state.cycle) + 1;
    return true;
}

// Note a register access inside a vector loop: an iteration must not
// read a register another iteration writes, since the order differs from
// a LOOP's.
void Processor::note_access(int address, bool write, PassState &state) const {
    if (!state.vector || address <= 0 || address >= register_count) {
        return;
    }
    VectorRun &run = *state.vector;
    if (!write) {
        run.readers[address].insert(run.element);
        return;
    }
    const auto [entry, first] = run.writer.try_emplace(address, run.element);
    if (!first && entry->second != run.element) {
        entry->second = -1;
    }
}

// A vector loop: the body instruction by instruction, each for every
// element in turn (docs/csp_manual.md, LOOP). The loop's index register
// steps per element; each element has its own copy of the other index
// register and its own flags. Afterwards both index registers and the
// flags are as the last element left them, as after a LOOP.
void Processor::run_vector(const Instruction &loop, PassState &state) {
    const auto own = (static_cast<uint8_t>(loop.a) & 1) ? IndexRegister::j
                                                        : IndexRegister::i;
    const auto other =
            own == IndexRegister::i ? IndexRegister::j : IndexRegister::i;
    const size_t start = state.pc;
    const size_t end   = start + loop.r;
    const int64_t count =
            read_operand(loop.x, state) & ((int64_t{1} << word_bits) - 1);
    const int stride = read_operand(loop.y, state);
    if (count > max_vector_length || end > program_.size()) {
        state.report.errors.push_back("vector loop over more than "
                                      + std::to_string(max_vector_length)
                                      + " elements, or past the program's end");
        state.pc = end;
        return;
    }

    struct Element {
        int other_index;
        Flags flags;
        int64_t flags_ready;
        int64_t index_ready;
    };
    Scoreboard &board = state.scoreboard;
    int &own_index    = index_[static_cast<size_t>(own)];
    int &other_index  = index_[static_cast<size_t>(other)];
    const int base    = own_index;
    std::vector<Element> elements(
            static_cast<size_t>(count),
            {other_index, flags_, board.flags_ready, board.index_ready});

    state.vector = VectorRun{other, 0, {}, {}};
    for (size_t at = start; at < end && !state.stopped; ++at) {
        const Instruction instruction = Instruction::decode(program_[at]);
        for (int element = 0; element < count; ++element) {
            Element &mine = elements[static_cast<size_t>(element)];
            own_index     = modulo_address(base + int64_t{element} * stride);
            other_index   = mine.other_index;
            flags_        = mine.flags;
            board.flags_ready     = mine.flags_ready;
            board.index_ready     = mine.index_ready;
            state.vector->element = element;
            if (!issue_or_stop(instruction, at, state)) {
                break;
            }
            execute(instruction, state);
            mine = {other_index, flags_, board.flags_ready, board.index_ready};
        }
    }

    const VectorRun run = *state.vector;
    state.vector.reset();
    for (const auto &[address, writer] : run.writer) {
        const auto readers = run.readers.find(address);
        const bool shared  = readers != run.readers.end()
                            && (writer < 0 || readers->second.size() > 1
                                || *readers->second.begin() != writer);
        if (shared) {
            char hex[8];
            std::snprintf(hex, sizeof hex, "0x%03x", address);
            state.report.errors.push_back(
                    std::string("vector loop iterations share register ")
                    + hex);
        }
    }

    own_index = modulo_address(base + count * int64_t{stride});
    if (count > 0) {
        const Element &last = elements.back();
        other_index         = last.other_index;
        flags_              = last.flags;
        for (const Element &element : elements) {
            board.flags_ready =
                    std::max(board.flags_ready, element.flags_ready);
        }
        board.front_ready =
                std::max(board.front_ready, state.cycle + barrier_latency);
    }
    board.index_ready = 0;
    state.pc          = end;
}

// ---- one instruction ------------------------------------------------------

void Processor::execute(const Instruction &instruction, PassState &state) {
    const bool is_wide =
            instruction.a == ASelect::wide && has_wide_form(instruction.op);

    // The A operand in the accumulator's format.
    auto a_value = [&]() -> Wide {
        switch (instruction.a) {
        case ASelect::zero:
            return 0;
        case ASelect::result:
            return from_word(read_operand(instruction.r, state));
        case ASelect::accumulator:
            return accumulator_;
        case ASelect::wide:
            return from_wide(read_wide_operand(instruction.r, state));
        }
        return 0;
    };
    // The Y operand in the accumulator's format, wide in a wide instruction.
    auto y_value = [&]() -> Wide {
        return is_wide ? from_wide(read_wide_operand(instruction.y, state))
                       : from_word(read_operand(instruction.y, state));
    };
    auto y_raw = [&]() -> int64_t {
        return is_wide ? read_wide_operand(instruction.y, state)
                       : read_operand(instruction.y, state);
    };
    // Store a result in the accumulator's format to R: saturated, or wrapped.
    auto store = [&](Wide result, bool wraps) {
        const int bits = is_wide ? wide_bits : word_bits;
        const Wide reduced =
                result >> (is_wide ? wide_to_accumulator : word_to_accumulator);
        const Reduced value = wraps ? Reduced{wrap(reduced, bits), false}
                                    : saturate(reduced, bits);
        if (is_wide) {
            write_wide_operand(instruction.r, value.value, state);
        } else {
            write_operand(instruction.r, static_cast<int32_t>(value.value),
                          state);
        }
        set_flags(value.value, value.overflow);
    };
    // Store a raw word to R, setting N and Z.
    auto store_word = [&](int64_t raw, bool sets_flags) {
        const int32_t value = static_cast<int32_t>(sign_extend(raw, word_bits));
        write_operand(instruction.r, value, state);
        if (sets_flags) {
            set_flags(value, false);
        }
    };

    switch (instruction.op) {
    case Opcode::nop:
        break;

    case Opcode::mac: {
        const int64_t x = read_operand(instruction.x, state);
        store(a_value() + product(x, y_raw(), is_wide), false);
        break;
    }
    case Opcode::macw: {
        const int64_t x = read_operand(instruction.x, state);
        store(a_value() + product(x, y_raw(), is_wide), true);
        break;
    }
    case Opcode::interp: {
        // Y - A in Q4.32, saturated to 36 bits: the multiplier's input
        // (#220, decision 3a). Exact unless |Y - A| >= 8, or A comes from
        // the accumulator with fraction bits below Q4.32.
        const Wide a    = a_value();
        const int64_t x = read_operand(instruction.x, state);
        const Reduced delta =
                saturate((y_value() - a) >> wide_to_accumulator, wide_bits);
        store(a + Wide{delta.value} * x, false);
        break;
    }
    case Opcode::acc: {
        const int64_t x = read_operand(instruction.x, state);
        const Wide sum =
                a_value()
                + product(x, read_operand(instruction.y, state), false);
        accumulator_ = saturate(sum, accumulator_bits).value;
        break;
    }
    case Opcode::add3: {
        const Wide x = from_word(read_operand(instruction.x, state));
        store(a_value() + x + y_value(), false);
        break;
    }
    case Opcode::sel: {
        const int64_t x = read_operand(instruction.x, state);
        const int64_t y = read_operand(instruction.y, state);
        store_word(flags_.negative ? y : x, false);
        break;
    }
    case Opcode::cmp: {
        const Wide difference = from_word(read_operand(instruction.x, state))
                                - from_word(read_operand(instruction.y, state));
        store(difference, false);
        break;
    }
    case Opcode::min:
    case Opcode::max: {
        const int64_t x = read_operand(instruction.x, state);
        const int64_t y = read_operand(instruction.y, state);
        store_word(instruction.op == Opcode::min ? std::min(x, y)
                                                 : std::max(x, y),
                   true);
        break;
    }
    case Opcode::andxor: {
        const int64_t a =
                instruction.a == ASelect::zero
                        ? 0
                        : saturate(a_value() >> word_to_accumulator, word_bits)
                                  .value;
        const int64_t x = read_operand(instruction.x, state);
        const int64_t y = read_operand(instruction.y, state);
        store_word((x & y) ^ a, true);
        break;
    }
    case Opcode::shift: {
        const int64_t count = read_operand(instruction.y, state);
        store(shift_by(a_value(), count), false);
        break;
    }
    case Opcode::abs: {
        const Wide x = from_word(read_operand(instruction.x, state));
        store(x < 0 ? -x : x, false);
        break;
    }
    case Opcode::skip: {
        const auto condition = static_cast<Condition>(instruction.x);
        bool taken           = false;
        switch (condition) {
        case Condition::always:
            taken = true;
            break;
        case Condition::negative:
            taken = flags_.negative;
            break;
        case Condition::positive:
            taken = !flags_.negative;
            break;
        case Condition::zero:
            taken = flags_.zero;
            break;
        case Condition::nonzero:
            taken = !flags_.zero;
            break;
        case Condition::overflow:
            taken = flags_.overflow;
            break;
        default:
            state.report.errors.push_back("SKIP with unknown condition "
                                          + std::to_string(instruction.x));
        }
        if (taken) {
            state.skip = instruction.y;
        }
        break;
    }
    case Opcode::idx: {
        const int64_t sum = int64_t{read_operand(instruction.x, state)}
                            + read_operand(instruction.y, state);
        const auto which =
                (instruction.r & 1) ? IndexRegister::j : IndexRegister::i;
        index_[static_cast<size_t>(which)] =
                modulo_address(sum); // visible at once
        break;
    }
    case Opcode::loop: {
        if (static_cast<uint8_t>(instruction.a) & 2) {
            run_vector(instruction, state);
            break;
        }
        const auto which    = (static_cast<uint8_t>(instruction.a) & 1)
                                      ? IndexRegister::j
                                      : IndexRegister::i;
        const size_t length = instruction.r;
        // The count is unsigned: a negative raw value is a huge count,
        // which the pass limit stops.
        const int64_t count = read_operand(instruction.x, state)
                              & ((int64_t{1} << word_bits) - 1);
        const int stride   = read_operand(instruction.y, state);
        const size_t start = state.pc; // already past the LOOP instruction
        const size_t end   = start + length;
        if (length == 0) {
            state.report.errors.push_back("LOOP with an empty body");
            break;
        }
        if (count <= 0) {
            state.pc = end; // the body runs no times
            break;
        }
        if (!state.loops.empty()) {
            const Loop &outer = state.loops.back();
            if (state.loops.size() >= 2 || outer.index == which
                || end > outer.end) {
                state.report.errors.push_back(
                        "LOOP nested more than one level, on the same index "
                        "register, or past its outer loop's end");
                break;
            }
        }
        state.loops.push_back({which, start, end, count, stride});
        break;
    }
    }
}

// Loop ends at the current pc: step the index register; repeat the body
// or leave the loop, then check the outer loop, which may end at the same
// place.
void Processor::end_loops(PassState &state) {
    while (!state.loops.empty() && state.pc == state.loops.back().end) {
        Loop &loop       = state.loops.back();
        int &index_value = index_[static_cast<size_t>(loop.index)];
        index_value      = modulo_address(int64_t{index_value} + loop.stride);
        if (--loop.remaining > 0) {
            state.pc = loop.start;
            break;
        }
        state.loops.pop_back();
    }
}

// ---- one pass -------------------------------------------------------------

PassReport Processor::pass() {
    PassState state;
    ++pass_count_;
    registers_[io_base] =
            static_cast<int32_t>(sign_extend(pass_count_, word_bits));

    if (held_) {
        // No program, but the pass still ends: the window applies every
        // committed write, and the sink pages flip as at every pass end.
        state.report.writes_applied = apply_window(cycles_per_pass);
        active_page_                = 1 - active_page_;
        return state.report;
    }

    // Each instruction runs to completion before the next, which sees
    // everything it did; the cycle it issues in follows the RTL's
    // interlocks. Instructions issue before cycle 1472.
    while (state.pc < program_.size() && !state.stopped) {
        const Instruction instruction = Instruction::decode(program_[state.pc]);
        if (!issue_or_stop(instruction, state.pc, state)) {
            break;
        }
        ++state.pc;
        if (state.skip > 0) {
            --state.skip;
        } else {
            execute(instruction, state);
        }
        end_loops(state);
    }

    // Every sink word the program has ever written must be written every
    // pass, or the partials would see a stale page every other pass.
    owned_sinks_.insert(state.sinks_written.begin(), state.sinks_written.end());
    std::ranges::set_difference(owned_sinks_, state.sinks_written,
                                std::back_inserter(state.report.stale_sinks));

    state.report.writes_applied = apply_window(write_window);
    active_page_                = 1 - active_page_;
    return state.report;
}

} // namespace csp
