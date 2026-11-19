// selftest.cpp — the boot self-test's instructions (see selftest.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "selftest.hpp"

namespace csp::selftest {

namespace {

constexpr IndexRegister j = IndexRegister::j;

constexpr ASource from_zero = ASource::zero;
constexpr ASource in_place  = ASource::result;

// Register 0 reads zero and takes no write: the zero of a sum, and the
// result of a CMP wanted for its flags alone.
constexpr Operand discard{Operand::Mode::direct, 0};
constexpr Source zero{discard, 0};

constexpr int pass = io_base; // the pass counter, an input

constexpr int32_t one        = word_one;
constexpr int32_t eighth     = word_one / 8;
constexpr int32_t minus_four = -4 * word_one;

// Two words, eight apart, as a table an index reaches into.
constexpr int table      = 0x063;
constexpr int table_0    = table;
constexpr int table_1    = table + 8;
constexpr int table_read = 0x065;

// The counts' own words.
constexpr int one_raw    = 0x110; // 1.0, for MACW's product of 1 raw step
constexpr int test_bit   = 0x108;
constexpr int test_half  = 0x10A;
constexpr int test_chain = 0x10C;
constexpr int run_one    = 0x3FD;

Operand to(int address) {
    return Operand::direct(address);
}

Source from(int address) {
    return Source::reg(Operand::direct(address));
}

// A raw value in the row: a number, a count of places, an address.
Source immediate(int32_t raw) {
    return Source::imm(raw);
}

} // namespace

void build(ProgramBuilder::Built &built) {
    ProgramBuilder program;

    // the pass counter's low bit, and what follows from it: the half's
    // choice by SHIFT, and a table read through IDX
    program.andxor(to(res_pass_bit), from_zero, from(pass), immediate(1));
    program.andxor(to(res_half), from_zero, from(pass), immediate(1));
    program.shift(to(res_half), in_place, immediate(3));
    // one immediate a row: the other operand is register 0
    program.add3(to(table_0), from_zero, immediate(one), zero);
    program.add3(to(table_1), from_zero, immediate(eighth), zero);
    program.idx(j, immediate(table), from(res_half));
    program.mac(to(table_read), from_zero, Source::reg(Operand::indexed(j, 0)),
                immediate(one));
    program.add3(to(res_chain), from_zero, from(res_half), from(table_read));

    // a chain of arithmetic, each instruction reading the one before
    program.abs(to(res_abs), immediate(minus_four));
    program.mac(to(res_mac), from_zero, from(res_abs), immediate(eighth));
    program.add3(to(res_add3), from_zero, from(res_mac), immediate(minus_four));
    program.cmp(discard, immediate(minus_four), zero);
    // negative: Y, 0.125
    program.sel(to(res_sel), Condition::negative, from(table_0),
                immediate(eighth));
    program.max(to(res_max), from(res_abs), immediate(minus_four));
    program.min(to(res_min), from(res_abs), immediate(minus_four));

    // the counter that wraps
    program.add3(to(one_raw), from_zero, immediate(one), zero);
    program.macw(to(count_passes), in_place, from(one_raw), immediate(1));
    // the copies of the pass counter, each one row with no chain: the pass
    // counter and all ones through the logic unit, the pass counter times
    // 1.0 through the multiply-add
    program.andxor(to(pass_via_logic), from_zero, from(pass), immediate(-1));
    program.mac(to(pass_via_dsp), from_zero, from(pass), immediate(one));
    program.andxor(to(pass_via_logic_a), from_zero, from(pass), immediate(-1));
    program.andxor(to(pass_via_logic_b), from_zero, from(pass), immediate(-1));
    // the counts
    program.add3(to(count_total), in_place, immediate(1), zero);
    program.andxor(to(test_bit), from_zero, from(pass), immediate(1));
    program.add3(to(count_odd), in_place, from(test_bit), zero);
    program.add3(to(test_half), from_zero, from(res_half), zero);
    program.shift(to(test_half), in_place, immediate(-3));
    program.add3(to(count_half_odd), in_place, from(test_half), zero);
    program.andxor(to(test_chain), from_zero, from(res_chain), immediate(8));
    program.shift(to(test_chain), in_place, immediate(-3));
    program.add3(to(count_chain_odd), in_place, from(test_chain), zero);

    // the passes this run made
    program.add3(to(run_one), from_zero, immediate(one), zero);
    program.macw(to(run_count), in_place, from(run_one), immediate(1));

    program.build(built);
}

} // namespace csp::selftest
