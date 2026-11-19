// selftest.hpp — the CSP's boot self-test, as a program
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What the firmware runs once at boot, to see that the chip does what the
// model says (engine_selftest.cpp). Scalar code only (#235): instructions
// that sit in dependent chains, worked a pass at a time into registers of
// their own, and counters that follow the pass counter's low bit through
// ANDXOR, SHIFT and IDX. The schedule the builder lays out is part of what is
// tested: the chip runs the rows as placed, with no interlock, so a wrong
// latency shows as a wrong result.
//
// The registers are the test's own choice: the firmware clears every
// register after the test, before the control program's image goes in.
//
// No hardware and no RTOS: the host's tools, tests and benches build the same
// program.

#pragma once

#include "program_builder.hpp"

namespace csp::selftest {

// ---- what the chain leaves, the same every pass -------------------------------

inline constexpr int res_pass_bit = 0x062; // the pass counter's low bit
inline constexpr int res_half     = 0x064; // the half's choice, 0 or 8
inline constexpr int res_chain    = 0x066; // 0x4000 (half 0) or 0x808 (half 1)
inline constexpr int res_abs      = 0x068; // |−4.0| = 4.0
inline constexpr int res_mac      = 0x06A; // 4.0 × 0.125 = 0.5
inline constexpr int res_add3     = 0x06C; // 0.5 − 4.0 = −3.5
inline constexpr int res_sel      = 0x06E; // the select after a compare
inline constexpr int res_max      = 0x116; // max(4.0, −4.0) = 4.0
inline constexpr int res_min      = 0x118; // min(4.0, −4.0) = −4.0

// ---- counts that do not depend on when the firmware looks ---------------------
//
// Over every pass the test runs: how many passes there were, how many had
// the pass counter's low bit set, and in how many of those the half's choice
// and the table read (which come from that bit through ANDXOR, SHIFT and
// IDX) said "second". The firmware reads them twice, some milliseconds
// apart, and compares the differences: the second two must equal the first.

inline constexpr int count_total     = 0x100;
inline constexpr int count_odd       = 0x102;
inline constexpr int count_half_odd  = 0x104;
inline constexpr int count_chain_odd = 0x106;
// A counter that wraps, for a capture of any length: the others saturate at
// the largest word after 2.7 s, which the firmware's reads of differences do
// not mind. The probe's pair here, streamed over S/PDIF
// (spdif_capture.py stream --probe-counter), must step once a pass.
inline constexpr int count_passes = 0x10E;

// Copies of the pass counter, in aligned pairs the firmware's probe reads
// from one pass: a reader that peeks a pair thousands of times at a raised
// clock and counts the reads whose halves disagree measures the miss rate.
// The first pair counts the multiply-add's misses (against the logic unit's
// copy), the second the logic unit's own.
inline constexpr int pass_via_logic   = 0x112; // through the logic unit
inline constexpr int pass_via_dsp     = 0x113; // through the multiply-add
inline constexpr int pass_via_logic_a = 0x114;
inline constexpr int pass_via_logic_b = 0x115;

// The passes this run made, for the chip check (tools/lab/chip_check.py and
// `csp match`, as every program in tools/csp/programs/checks): one a pass
// from the fill's value, wrapping.
inline constexpr int run_count = 0x3FE;

// The program, scheduled and encoded into `built`.
void build(ProgramBuilder::Built &built);

} // namespace csp::selftest
