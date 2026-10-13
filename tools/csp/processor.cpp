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
    registers_[address]     = static_cast<int32_t>(raw >> word_bits);
    registers_[address + 1] = static_cast<int32_t>(sign_extend(raw, word_bits));
}

void Processor::set_flags(int64_t result, bool overflow) {
    flags_ = {result < 0, result == 0, overflow};
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
        state.pending.push_back(
                {state.cycle + index_delay + 1, which, modulo_address(sum)});
        break;
    }
    case Opcode::loop: {
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

// ---- the pipeline's timing ------------------------------------------------
//
// rtl/csp/csp_core.sv's hazard rules, which decide how many cycles a pass
// takes and so which instructions see a new i or j (an IDX is visible from
// the fourth cycle after it): INTERP and ADD3 wait a cycle for an A, Y or
// accumulator the instruction just before writes; LOOP waits for a count or
// stride either of the two before write, and then holds fetch for two
// cycles. Addresses are compared as resolved, whatever they name.

namespace {

bool overlaps(int write_address, bool write_wide, int read_address,
              bool read_wide) {
    const int write_last =
            (write_address + (write_wide ? 1 : 0)) % address_space;
    const int read_last = (read_address + (read_wide ? 1 : 0)) % address_space;
    return write_address <= read_last && read_address <= write_last;
}

bool writes_result(Opcode op) {
    return !(op == Opcode::nop || op == Opcode::loop || op == Opcode::acc
             || op == Opcode::skip || op == Opcode::idx);
}

bool uses_a(const Instruction &instruction) {
    const Opcode op = instruction.op;
    return (instruction.a == ASelect::result || instruction.a == ASelect::wide)
           && (op == Opcode::mac || op == Opcode::macw || op == Opcode::interp
               || op == Opcode::add3 || op == Opcode::andxor
               || op == Opcode::shift);
}

bool uses_accumulator(const Instruction &instruction) {
    const Opcode op = instruction.op;
    return instruction.a == ASelect::accumulator
           && (op == Opcode::mac || op == Opcode::macw || op == Opcode::interp
               || op == Opcode::acc || op == Opcode::add3
               || op == Opcode::andxor || op == Opcode::shift);
}

bool uses_y(Opcode op) {
    return !(op == Opcode::nop || op == Opcode::skip || op == Opcode::abs);
}

bool wide_y(const Instruction &instruction) {
    return instruction.a == ASelect::wide && has_wide_form(instruction.op)
           && instruction.op != Opcode::shift;
}

} // namespace

Processor::SlotWrite
Processor::writes_of(const Instruction &instruction) const {
    SlotWrite slot;
    slot.writes_register = writes_result(instruction.op);
    slot.address         = resolve(instruction.r);
    slot.wide = instruction.a == ASelect::wide && has_wide_form(instruction.op);
    slot.writes_accumulator = instruction.op == Opcode::acc;
    return slot;
}

bool Processor::hazard(const Instruction &instruction,
                       const PassState &state) const {
    auto produces = [](const SlotWrite &producer, int address, bool wide) {
        return producer.writes_register
               && overlaps(producer.address, producer.wide, address, wide);
    };
    const Opcode op = instruction.op;
    if (op == Opcode::interp || op == Opcode::add3) {
        const SlotWrite &previous = state.recent[0];
        if (uses_a(instruction)
            && produces(previous, resolve(instruction.r),
                        instruction.a == ASelect::wide)) {
            return true;
        }
        if (uses_y(op)
            && produces(previous, resolve(instruction.y),
                        wide_y(instruction))) {
            return true;
        }
        if (uses_accumulator(instruction) && previous.writes_accumulator) {
            return true;
        }
    }
    if (op == Opcode::loop) {
        for (const SlotWrite &producer : state.recent) {
            if (produces(producer, resolve(instruction.x), false)
                || produces(producer, resolve(instruction.y), false)) {
                return true;
            }
        }
    }
    return false;
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

// One cycle passes: what was decoded in it becomes the newest producer.
void Processor::advance(PassState &state, const SlotWrite &decoded) {
    state.recent[1] = state.recent[0];
    state.recent[0] = decoded;
    ++state.cycle;
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

    auto apply_pending = [&] {
        while (!state.pending.empty()
               && state.pending.front().visible_from <= state.cycle) {
            const PendingIndex &pending                = state.pending.front();
            index_[static_cast<size_t>(pending.index)] = pending.value;
            state.pending.pop_front();
        }
    };

    while (state.pc < program_.size()) {
        const Instruction instruction = Instruction::decode(program_[state.pc]);

        // Decode, waiting while a hazard holds it in D. Each cycle it is
        // decoded again with the index registers of that cycle.
        apply_pending();
        while (hazard(instruction, state)) {
            advance(state, SlotWrite{});
            apply_pending();
        }
        if (state.cycle >= max_program_length) {
            state.report.errors.push_back("pass longer than "
                                          + std::to_string(max_program_length)
                                          + " cycles");
            break;
        }

        const SlotWrite decoded = writes_of(instruction);
        if (trace_) {
            std::fprintf(stderr, "model pc %zu cycle %lld i %d j %d\n",
                         state.pc, static_cast<long long>(state.cycle),
                         index_[0], index_[1]);
        }
        ++state.pc;
        if (state.skip > 0) {
            --state.skip;
        } else {
            execute(instruction, state);
        }
        if (instruction.op != Opcode::loop) {
            end_loops(state);
        }
        advance(state, decoded);
        if (instruction.op == Opcode::loop) {
            // Fetch waits two cycles for the count. A count of 0 has
            // jumped past the body, maybe onto the outer loop's end, which
            // the hardware handles at the end of the first of them.
            apply_pending();
            end_loops(state);
            advance(state, SlotWrite{});
            advance(state, SlotWrite{});
        }
    }
    for (const PendingIndex &pending : state.pending) {
        index_[static_cast<size_t>(pending.index)] = pending.value;
    }
    state.report.cycles = static_cast<int>(state.cycle);

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
