// csp_test.cpp — host tests for the CSP reference model, builder and assembler
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every instruction at its edges (formats, truncation, saturation, wrap,
// flags), the rules a program can see (the index registers, loops,
// the write queue and swap, the hold, pass limits, sink pages), the
// schedule the builder lays out (checked by the model's scoreboard), the
// assembler's checks, and the programs in tools/csp/programs.
//
//   make csp-test

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "../assembler.hpp"
#include "../processor.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "csp/program_builder.hpp"

namespace {

int failures = 0;
int checks   = 0;

void check(bool ok, const std::string &what) {
    ++checks;
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        ++failures;
    }
}

void check_equal(int64_t got, int64_t want, const std::string &what) {
    ++checks;
    if (got != want) {
        std::printf("FAIL %s: got %lld, want %lld\n", what.c_str(), static_cast<long long>(got),
                    static_cast<long long>(want));
        ++failures;
    }
}

int32_t q(double value) {
    return static_cast<int32_t>(std::llround(value * csp::word_one));
}

int64_t q_wide(double value) {
    return std::llround(value * static_cast<double>(int64_t{1} << csp::wide_fraction_bits));
}

// A program assembled and loaded on a fresh processor, with any register
// values set while the CSP is held.
class Machine {
public:
    explicit Machine(std::string_view source) : program(csp::assemble(source)) {
        for (const csp::Diagnostic &d : program.diagnostics) {
            if (d.error) std::printf("  assembly error, line %d: %s\n", d.line, d.message.c_str());
        }
        check(program.ok, "program assembles");
    }

    Machine &set(const std::string &name, int32_t raw) {
        processor.write(address(name), raw);
        return *this;
    }

    Machine &set_wide(const std::string &name, int64_t raw) {
        processor.write_wide(address(name), raw);
        return *this;
    }

    // Apply the settings while held, load, release.
    Machine &start() {
        processor.swap();
        while (processor.queued_writes() > 0) processor.pass();
        check(processor.load(program.image), "program loads while held");
        processor.release();
        return *this;
    }

    // A pass; the model's errors are test failures.
    csp::PassReport run() {
        const csp::PassReport report = processor.pass();
        for (const std::string &error : report.errors) std::printf("  model: %s\n", error.c_str());
        return report;
    }

    int32_t get(const std::string &name) const { return processor.read(address(name)); }
    int64_t get_wide(const std::string &name) const { return processor.read_wide(address(name)); }

    int address(const std::string &name) const {
        const auto found = program.symbols.find(name);
        if (found == program.symbols.end()) {
            std::printf("FAIL unknown name %s\n", name.c_str());
            ++failures;
            return 0;
        }
        return found->second;
    }

    csp::Program program;
    csp::Processor processor;
};

bool has_diagnostic(const csp::Program &program, bool error, std::string_view text) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        if (d.error == error && d.message.find(text) != std::string::npos) return true;
    }
    return false;
}

// The cycles a program's pass takes as scheduled, which the model confirms
// by running it without an early read.
int cycles_of(const std::string &source) {
    Machine m(source);
    m.start();
    const csp::PassReport report = m.run();
    check(report.errors.empty(), "the schedule runs without an early read");
    check_equal(report.cycles, m.program.cycles, "the model counts the cycles the assembler scheduled");
    return report.cycles;
}

// ---- encoding ---------------------------------------------------------------

void test_encoding() {
    using csp::Operand;
    csp::Word word;
    word.op   = 0x5A;
    word.cond = static_cast<uint8_t>(csp::Condition::negative);
    word.r    = Operand::indexed(csp::IndexRegister::i, 0);
    word.x    = Operand::indexed(csp::IndexRegister::j, 2);
    word.y    = Operand::direct(0x3FF);
    word.imm  = 0x3FFFD;
    const csp::Row row = word.encode();
    check(row.high < (uint64_t{1} << 36) && row.low < (uint64_t{1} << 36), "a row is two 36-bit dwords");
    check(csp::Word::decode(row) == word, "a word encodes and decodes round-trip");
    check_equal(static_cast<int64_t>(row.high >> 28), 0x5A, "op is bits 71:64");
    check(csp::Word::decode(csp::Row{}).op == 0, "an all-zero row is op 0, the NOP");
    check(Operand::decode(0x805) == Operand::indexed(csp::IndexRegister::j, 5), "operand 10 0000000101 is j|5");
    check(Operand::decode(0x0FF) == Operand::direct(0xFF), "operand 00 0011111111 is direct 255");
    check(Operand::decode(0xC00).mode == Operand::Mode::immediate, "mode 3 is an immediate");

    csp::Control control{csp::Unit::multiply_add, csp::Writes::pair, csp::ASource::result, true, true,
                         csp::ConditionKind::flags, true, true, 0};
    check(csp::Control::decode(control.encode()) == control, "a control word encodes and decodes round-trip");
    check_equal(csp::control_of(csp::Op::nop, false, csp::ASource::zero).encode(), 0, "NOP's control word is 0");
    // which operands a row reads: the chip parks the read ports of the others
    const auto reads = [](csp::Op op) {
        const csp::Control c = csp::control_of(op, false, csp::ASource::zero);
        return (c.reads_x ? 1 : 0) | (c.reads_y ? 2 : 0);
    };
    check_equal(reads(csp::Op::mac), 3, "MAC reads X and Y");
    check_equal(reads(csp::Op::abs), 1, "ABS reads X only");
    check_equal(reads(csp::Op::shift), 2, "SHIFT reads Y only (X is not read)");
    check_equal(reads(csp::Op::idx), 3, "IDX reads X and Y");
    check_equal(reads(csp::Op::loop), 0, "LOOP reads nothing: its numbers are in the word");
    check_equal(reads(csp::Op::nop), 0, "NOP reads nothing");
}

// ---- arithmetic ---------------------------------------------------------------

const char *registers = R"(
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .wide W_, 0x064
        .wide V_, 0x066
)";

void test_mac() {
    Machine m(std::string(registers) + R"(
        MAC   A_, 0, B_, C_
        MAC   D_, D_, B_, C_
)");
    m.set("B_", q(0.5)).set("C_", q(0.5)).set("D_", q(1.0)).start().run();
    check_equal(m.get("A_"), q(0.25), "MAC: 0.5 × 0.5 = 0.25");
    check_equal(m.get("D_"), q(1.25), "MAC with A = R accumulates");

    Machine sat(std::string(registers) + "MAC A_, 0, B_, C_\n");
    sat.set("B_", q(7.0)).set("C_", q(7.0)).start().run();
    check_equal(sat.get("A_"), csp::largest(18), "MAC saturates at the top");
    check(sat.processor.flags().overflow, "MAC sets V when it saturates");

    Machine tiny(std::string(registers) + R"(
        MAC   A_, 0, B_, B_
        MAC   C_, 0, B_, D_
)");
    tiny.set("B_", 1).set("D_", -1).start().run();
    check_equal(tiny.get("A_"), 0, "MAC truncates 2⁻²⁸ to 0");
    check_equal(tiny.get("C_"), -1, "MAC truncates −2⁻²⁸ toward minus infinity");
}

void test_macw_and_wide() {
    Machine m(std::string(registers) + R"(
        .const ONE, 1.0
        MACW  A_, A_, B_, ONE
        MACW.w W_, ONE, V_
)");
    m.set("A_", q(7.5)).set("B_", q(1.0));
    m.set_wide("W_", q_wide(7.75)).set_wide("V_", q_wide(0.5)).start().run();
    check_equal(m.get("A_"), q(-7.5), "MACW wraps 7.5 + 1.0 to −7.5");
    check(!m.processor.flags().overflow, "MACW does not set V");
    check_equal(m.get_wide("W_"), q_wide(-7.75), "MACW.w wraps a wide phase");
    check_equal(m.get("W_"), q(-7.75), "a wide register's upper word reads as Q4.14");
}


void test_add3_sel_cmp_min_max() {
    Machine m(std::string(registers) + R"(
        ADD3  A_, 0, B_, C_
        CMP   ZERO, B_, C_
        SEL   D_, B_, C_
        MIN   W_, B_, C_
        MAX   V_, B_, C_
)");
    m.set("B_", q(1.0)).set("C_", q(2.0)).start().run();
    check_equal(m.get("A_"), q(3.0), "ADD3: 1 + 2");
    check_equal(m.get("D_"), q(2.0), "SEL after CMP 1 − 2 < 0 picks Y");
    check_equal(m.get("W_"), q(1.0), "MIN");
    check_equal(m.get("V_"), q(2.0), "MAX");

    Machine sat(std::string(registers) + "ADD3 A_, 0, B_, C_\n");
    sat.set("B_", q(6.0)).set("C_", q(6.0)).start().run();
    check_equal(sat.get("A_"), csp::largest(18), "ADD3 saturates");
}

void test_andxor_shift_abs_nop() {
    Machine m(std::string(registers) + R"(
        ANDXOR A_, 0, B_, =#4
        SHIFT  C_, C_, =#2
        SHIFT  D_, D_, =#-3
        ABS    W_, =-8.0
        CMP    ZERO, =1.0, ZERO
        NOP
)");
    m.set("B_", 8).set("C_", q(1.5)).set("D_", -q(1.0) - 1).start().run();
    check_equal(m.get("A_"), 0, "ANDXOR maps stage 8 to 0 with mask 4");
    check_equal(m.get("C_"), q(6.0), "SHIFT left by 2");
    check_equal(m.get("D_"), -(q(1.0) / 8) - 1, "SHIFT right by 3 truncates toward minus infinity");
    check_equal(m.get("W_"), csp::largest(18), "ABS of −8 saturates to just under +8");
    check(!m.processor.flags().negative && !m.processor.flags().zero, "NOP leaves the flags of the CMP before it");

    Machine big(std::string(registers) + "SHIFT A_, A_, =#4\n");
    big.set("A_", q(1.0)).start().run();
    check_equal(big.get("A_"), csp::largest(18), "SHIFT left saturates");
}

// ---- rules a program can see ----------------------------------------------------

// The schedule changes the cycle count, never the result: a dependent
// instruction issues result_latency cycles after the one it reads, a
// reader of the flags state_latency after, the one
// after IDX index_latency after, and independent ones every cycle. The
// model runs the rows as placed and reports any read that comes early.
void test_schedule() {
    const auto cycles = [](std::string_view body) { return cycles_of(std::string(registers) + std::string(body)); };
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC B_, 0, =1.0, =1.0\n"), 2, "independent instructions issue every cycle");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC B_, 0, A_, =1.0\n"), csp::result_latency + 1,
                "a read of R waits for its write");
    check_equal(cycles(".reg W_LOWER, 0x065\nMAC.w W_, =1.0, V_\nMAC B_, 0, W_LOWER, =1.0\n"), csp::result_latency + 1,
                "a read of a pair's lower word waits for the wide write");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC C_, 0, B_, =1.0\n"), 2, "another register does not wait");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nSEL B_, =1.0, C_\n"), csp::state_latency + 1, "SEL waits for the flags");
    check_equal(cycles("IDX i, =#0x100, 0\nMAC B_, 0, =1.0, =1.0\n"), csp::index_latency + 1,
                "the instruction after IDX comes index_latency cycles on");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nNOP\nNOP\nNOP\nNOP\nNOP\nNOP\nMAC B_, 0, A_, =1.0\n"),
                csp::result_latency + 1, "a program's own NOPs count toward the wait");
}

// IDX takes effect for the instruction index_latency rows on; the
// index's bits sit beside the offset's.
void test_index() {
    Machine m(std::string(registers) + R"(
        .equ BASE, 0x100
        IDX   i, =#BASE, 0
        MAC   [i+1], 0, =1.0, =1.0      ; the next instruction: the new i
        IDX   i, =#0x180, 0
        MAC   [i+2], 0, =2.0, =2.0
        IDX   j, =#0x200, B_            ; a register adds to the base
        MAC   [j+1], 0, =0.5, =0.5
)");
    check(m.program.diagnostics.empty(), "IDX followed by a use: no warning");
    m.set("B_", 0x30).start();
    const csp::PassReport report = m.run();
    check_equal(m.processor.read(0x101), q(1.0), "the instruction after IDX sees the new i");
    check_equal(m.processor.read(0x182), q(4.0), "and again after the second IDX");
    check_equal(m.processor.read(0x231), q(0.25), "IDX adds X and Y; the offset ORs in");
    check_equal(m.processor.index(csp::IndexRegister::j), 0x230, "j holds the sum");
    check(report.errors.empty(), "without an early read");

    // The chip ORs the offset into the index: an offset whose bits the
    // index already has is a different address from the sum, and reported.
    Machine overlap(std::string(registers) + "IDX i, =#0x204, 0\nMAC [i+4], 0, =1.0, =1.0\n");
    overlap.start();
    const csp::PassReport overlap_report = overlap.processor.pass();
    check(overlap_report.errors.size() == 1 && overlap_report.errors[0].find("overlap") != std::string::npos,
          "an offset overlapping the index's bits is reported");
    check_equal(overlap.processor.read(0x204), q(1.0), "and the chip's OR is what the model did");
}

// LOOP.vi runs its body instruction by instruction across all elements,
// in rounds of sixteen: the same results as LOOP.i when iterations are
// independent, with fewer waits; per-element flags and j; shared
// registers reported.
void test_vector_loops() {
    const std::string body = R"(
        .block ITEM
        .field X, 1
        .field DOUBLE, 1
        .field SIGN, 1
        .field ROW, 1
        .field PICK, 1
        .end
        .equ    ITEMS, 0x200
        .equ   TABLE, 0x300
        IDX    i, =#ITEMS, 0
)";
    const std::string loop_body = R"(
        MAC    [i+DOUBLE], 0, [i+X], =2.0     ; each needs the one before
        CMP    ZERO, [i+DOUBLE], ZERO         ;   flags, per element
        SEL    [i+SIGN], =1.0, [i+X]
        IDX    j, =#TABLE, [i+ROW]            ;   j, per element
        MAC    [i+PICK], 0, [j+0], =1.0
)";
    auto make = [&](const char *loop) {
        auto m = std::make_unique<Machine>(body + loop + loop_body);
        for (int item = 0; item < 8; ++item) {
            m->processor.write(0x200 + 8 * item, q(item % 2 ? 0.25 : -0.25));
            m->processor.write(0x200 + 8 * item + 3, item);
            m->processor.write(0x300 + item, q(0.125 * item));
        }
        m->start();
        return m;
    };
    auto scalar                         = make("        LOOP.i  5, =#8, =#8\n");
    auto vector                         = make("        LOOP.vi 5, =#8, =#8\n");
    const csp::PassReport scalar_report = scalar->run();
    const csp::PassReport vector_report = vector->run();
    check(vector->program.diagnostics.empty() && vector_report.errors.empty(), "a vector loop assembles and runs");
    check(scalar_report.errors.empty(), "the scalar loop runs");
    bool same = true;
    for (int address = 0x200; address < 0x240; ++address) {
        same = same && scalar->processor.read(address) == vector->processor.read(address);
    }
    check(same, "LOOP.vi gives LOOP.i's results");
    check_equal(vector->processor.read(0x200 + 2), q(-0.25), "SEL sees its own element's flags (negative: Y)");
    check_equal(vector->processor.read(0x200 + 8 + 2), q(1.0), "and the next element's (positive: X)");
    check_equal(vector->processor.read(0x200 + 8 * 5 + 4), q(0.625), "an element's [j+…] uses its own j");
    check_equal(vector->processor.index(csp::IndexRegister::j), 0x307, "after the loop, j is the last element's");
    // IDX and its wait rows, LOOP.vi, then the body's rows for each of the 8 elements, the
    // one bubble behind the first element. A dependent pair of rows is ceil(latency / elements) rows
    // apart: the MAC and the CMP that reads its result, and the IDX after the SEL (inside a
    // vector loop the index's base is unknown, so an indexed read waits for every earlier
    // indexed write).
    const int spacing_8 = (csp::result_latency + 7) / 8;
    check_equal(vector_report.cycles, csp::index_latency + 1 + 1 + (5 + 2 * (spacing_8 - 1)) * 8,
                "a vector loop of 8 elements: dependent rows ceil(latency / 8) apart, one bubble to enter, nothing else");
    check(scalar_report.cycles > vector_report.cycles, "the scalar loop waits inside each iteration");

    // Two elements a round: a dependent row is ceil(latency / 2) rows on.
    Machine two(body + "        LOOP.vi 2, =#2, =#8\n" + "        MAC [i+DOUBLE], 0, [i+X], =2.0\n"
                + "        MAC [i+PICK], 0, [i+DOUBLE], =1.0\n");
    two.start();
    const csp::PassReport two_report = two.run();
    check(two_report.errors.empty(), "a two-element loop is spaced by the latency");
    const int spacing_2 = (csp::result_latency + 1) / 2;
    check_equal(two_report.cycles, csp::index_latency + 1 + 1 + (2 + (spacing_2 - 1)) * 2,
                "ceil(latency / 2) - 1 wait rows between the dependent pair");

    Machine shared(body
                   + "        .reg T, 0x060\n"
                     "        LOOP.vi 2, =#8, =#8\n"
                     "        MAC T, 0, [i+X], =1.0\n"
                     "        MAC [i+PICK], 0, T, =1.0\n");
    shared.start();
    check(!shared.processor.pass().errors.empty(), "elements sharing a register are reported");
}

void test_loops() {
    Machine m(std::string(registers) + R"(
        .equ BASE, 0x200
        IDX    i, =#BASE, 0
        LOOP.i 1, =#4, =#16           ; 4 blocks of 16
        ADD3   [i+0], [i+0], =1.0, ZERO
        IDX    j, =#0x300, 0
        LOOP.i 3, =#2, =#1            ; outer: 2 passes over i
        NOP
        LOOP.j 1, =#3, =#1            ;   inner: 3 passes over j
        ADD3   [j+0], [j+0], =1.0, ZERO
        LOOP.i 1, =#0, =#1            ; count 0: the body is skipped
        MAC    A_, 0, =1.0, =1.0
        MAC    B_, 0, =1.0, =1.0
)");
    m.start();
    const csp::PassReport report = m.run();
    for (int block = 0; block < 4; ++block) {
        check_equal(m.processor.read(0x200 + 16 * block), q(1.0), "LOOP.i writes block " + std::to_string(block));
    }
    check_equal(m.processor.read(0x200 + 16 * 4), 0, "and no further");
    check_equal(m.processor.read(0x300), q(1.0), "nested loop: j+0 on the first outer pass");
    check_equal(m.processor.read(0x302), q(1.0), "j steps 3 times per inner loop");
    check_equal(m.processor.read(0x303), q(1.0), "and carries on in the second outer pass");
    check_equal(m.processor.read(0x305), q(1.0), "6 inner passes in all");
    check_equal(m.processor.read(0x306), 0, "and no more");
    check_equal(m.get("A_"), 0, "a count of 0 skips the body");
    check_equal(m.get("B_"), q(1.0), "and the program continues after it");
    check(report.errors.empty(), "loops run without errors");
    check_equal(report.cycles, m.program.cycles, "the model counts the cycles the assembler scheduled");

    // A loop whose body reads what its previous iteration wrote: the
    // schedule has the wait, so the second iteration reads the result.
    Machine chain(std::string(registers) + R"(
        LOOP.i 1, =#3, =#0
        ADD3   A_, A_, =1.0, ZERO
)");
    chain.start();
    const csp::PassReport chain_report = chain.run();
    check_equal(chain.get("A_"), q(3.0), "an accumulating loop body sees its own result");
    check(chain_report.errors.empty(), "because the schedule waits between iterations");
    check(chain_report.cycles >= 1 + 3 * 1 + 2 * (csp::result_latency - 1), "at the cost of the latency each time");
}

// A loop with a count of 0 whose body was the tail of its outer loop's
// body: skipping it lands on the outer loop's end, which must still step
// the outer index register and repeat the outer loop (found by the RTL
// co-simulation of the first revision, #220).
void test_empty_inner_loop_at_outer_end() {
    Machine m(std::string(registers) + R"(
        LOOP.j outer_end, =#3, =#1      ; outer: 3 passes, j steps by 1
        ADD3   A_, A_, =1.0, ZERO       ;   counts the outer passes
        LOOP.i outer_end, =#0, =#1      ;   inner: count 0, body ends with the outer's
        ADD3   B_, B_, =1.0, ZERO       ;     never runs
outer_end:
        MAC    C_, 0, =1.0, =1.0        ; after both
)");
    m.start();
    const csp::PassReport report = m.run();
    check_equal(m.get("A_"), q(3.0), "the outer loop still runs three times");
    check_equal(m.get("B_"), 0, "the empty inner loop's body never runs");
    check_equal(m.get("C_"), q(1.0), "the program continues after both");
    check_equal(m.processor.index(csp::IndexRegister::j), 3, "the outer loop stepped j three times");
    check(report.errors.empty(), "without errors");
}

// The chip has no stall, so what the front end used to wait for is rows: an
// IDX is followed by four NOPs, and a loop of count 0 is not there at all.
void test_decisions() {
    const csp::Program idx = csp::assemble(std::string(registers) + "IDX i, =#0x100, 0\nMAC A_, 0, =1.0, =1.0\n");
    check(idx.ok, "IDX assembles");
    check_equal(idx.image.length, 1 + (csp::index_latency - 1) + 1, "an IDX is followed by index_latency - 1 NOP rows");
    for (int row = 1; row < csp::index_latency; ++row) {
        check(csp::Word::decode(idx.image.rows[static_cast<size_t>(row)]).op == 0, "the row after an IDX is a NOP");
    }

    const csp::Program without = csp::assemble(std::string(registers) + "MAC A_, 0, =1.0, =1.0\n");
    const csp::Program with_empty = csp::assemble(std::string(registers) + "LOOP.i end, =#0, =#1\nMAC B_, 0, =2.0, =2.0\n"
                                                  "LOOP.j end2, =#0, =#1\nMAC D_, 0, =4.0, =4.0\nMAC C_, 0, =3.0, =3.0\n"
                                                  "end2:\nend:\nMAC A_, 0, =1.0, =1.0\n");
    check(with_empty.ok, "loops of count 0 assemble");
    check(with_empty.image.rows == without.image.rows && with_empty.image.length == without.image.length,
          "a loop of count 0 and its body, nested loops and all, leave no row");
    check_equal(with_empty.cycles, without.cycles, "and cost no cycle");

    check(has_diagnostic(csp::assemble("LOOP.i end, =#2, =#1\nIDX i, =#0x200, 0\nend:\nNOP\n"), true, "own index register"),
          "a loop body cannot set its own index register");
    check(csp::assemble(std::string(registers) + "LOOP.i end, =#2, =#1\nIDX j, =#0x200, 0\nend:\nNOP\n").ok,
          "but it may set the other");

}

void test_queue_and_swap() {
    Machine m(std::string(registers) + "MAC B_, 0, A_, =1.0\n");
    m.start();
    m.processor.write(m.address("A_"), q(1.0));
    m.run();
    check_equal(m.get("A_"), 0, "a queued write has no effect before a swap");
    m.processor.swap();
    m.run();
    check_equal(m.get("A_"), q(1.0), "after the swap, the window applies it at the end of the pass");
    check_equal(m.get("B_"), 0, "so the pass itself never saw it");
    m.run();
    check_equal(m.get("B_"), q(1.0), "the next pass does");

    for (int n = 0; n < 60; ++n) m.processor.write(0x100 + n, q(1.0));
    m.processor.swap();
    const csp::PassReport first = m.run();
    check_equal(first.writes_applied, csp::write_window, "the window applies 48 writes per pass");
    const csp::PassReport second = m.run();
    check_equal(second.writes_applied, 12, "and the rest in the next pass");
}

void test_hold() {
    Machine m(std::string(registers) + "ADD3 A_, A_, =1.0, ZERO\n");
    m.start();
    m.run();
    m.processor.hold();
    m.run();
    check_equal(m.get("A_"), q(1.0), "a held CSP runs no program");
    check(m.processor.load(m.program.image), "a program loads while held");
    m.processor.release();
    m.run();
    check_equal(m.get("A_"), q(2.0), "the hold clears no registers");
    check(!m.processor.load(m.program.image), "a program does not load while running");
}

void test_limits() {
    std::string source;
    for (int n = 0; n < csp::program_rows + 1; ++n) source += "NOP\n";
    check(has_diagnostic(csp::assemble(source), true, "IMEM holds"),
          "the assembler rejects a program over 1472 rows");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#1023, =#0\nNOP\n"), true, "the pass runs"),
          "the assembler rejects a pass over 1472 cycles");
    // 256 distinct control words would need more decode rows than the op
    // field reaches; the program's variants come to a handful
    const csp::Program program = csp::assemble(std::string(registers) + "MAC A_, 0, B_, C_\nMAC.w W_, B_, V_\n"
                                               + "SEL A_, B_, C_\nIDX i, =#0x100, 0\nIDX j, =#0x100, 0\n");
    check_equal(program.image.rom_used, csp::rom_reserved + 5, "distinct control words get a decode row each, after the NOP's and the vector loops' (IDX i and IDX j differ)");
}

void test_sinks() {
    Machine m(std::string(registers) + R"(
        IDX    i, =#0x800, 0
        MAC    [i+0], 0, A_, =1.0
        MAC    [i+1], 0, =1.0, =1.0
)");
    m.set("A_", q(0.5)).start();
    const csp::PassReport first = m.run();
    check_equal(m.processor.sink(0), q(0.5), "a sink written in a pass is published at its end");
    check(first.stale_sinks.empty(), "every owned sink written: none stale");
}

void test_firmware_sinks() {
    Machine m(std::string(registers) + "NOP\n");
    m.start();
    m.processor.write(csp::sink_base + 7, q(0.25));
    m.processor.write(csp::sink_base + csp::sink_count, q(1.0)); // beyond the sinks
    m.run();
    check_equal(m.processor.sink(7), 0, "a queued sink write waits for the swap");
    m.processor.swap();
    m.run();
    check_equal(m.processor.sink(7), q(0.25), "the window applies it, and the pass publishes it");
    m.run();
    check_equal(m.processor.sink(7), q(0.25), "it is in both pages, so the next flip keeps it");
    m.run();
    check_equal(m.processor.sink(7), q(0.25), "and the one after");
}

// ---- the assembler ----------------------------------------------------------------

void test_assembler() {
    check(has_diagnostic(csp::assemble("FOO r1, r2\n"), true, "unknown instruction"), "unknown instruction");
    check(has_diagnostic(csp::assemble("MAC r1100, 0, r1, r2\n"), true, "reaches 0–1023"), "direct operands reach 0–1023");
    check(has_diagnostic(csp::assemble("CMP.w r2, r4, r6\n"), true, "no wide form"), ".w on an instruction without one");
    check(has_diagnostic(csp::assemble("MAC r1, r2, r3, r4\n"), true, "must be 0 or the R"),
          "an A operand that is not 0 or R");
    check(has_diagnostic(csp::assemble("MAC r1, 0, =1.0, =2.0\n"), true, "one immediate a word"),
          "two different immediates in one word");
    check(csp::assemble("MAC r1, 0, =1.0, =1.0\n").ok, "the same immediate twice is one immediate");
    check(has_diagnostic(csp::assemble("LOOP.i 2, =#2, =#1\nLOOP.i 1, =#2, =#1\nNOP\n"), true, "different index"),
          "nested loops on the same index register");
    check(has_diagnostic(csp::assemble("LOOP.i 3, =#2, =#1\nLOOP.j 3, =#2, =#1\nNOP\nNOP\nNOP\n"), true,
                         "past its outer loop"),
          "an inner loop past its outer loop's end");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#2, =#1\n"), true, "past the program's end"),
          "a loop past the end of the program");
    check(has_diagnostic(csp::assemble(".wide W, 0x061\n"), true, "even"), "a wide register at an odd address");
    check(has_diagnostic(csp::assemble("MAC r64, 0, r1, r2\n"), true, "input"), "no result into an input register");

    const csp::Program block = csp::assemble(R"(
        .block VOICE
        .field LEVEL, 2
        .field STAGE, 1
        .end
)");
    check_equal(block.symbols.at("STAGE"), 2, ".field offsets add up");
    check_equal(block.symbols.at("VOICE_SIZE"), 3, ".end defines the block's size");
}

void test_labels_and_count() {
    // A LOOP closed by a label further on, as firmware authors
    // would write it: nobody counts body lengths by hand.
    Machine m(std::string(registers) + R"(
        LOOP.i done, =#3, =#0
        ADD3   A_, A_, =1.0, ZERO
        ADD3   B_, B_, =1.0, ZERO
done:   ADD3   D_, 0, =3.0, ZERO
)");
    m.start().run();
    check_equal(m.get("A_"), q(3.0), "LOOP closed by a label runs its whole body");
    check_equal(m.get("B_"), q(3.0), "both body instructions, three times");
    check_equal(m.get("D_"), q(3.0), "and the labelled instruction runs");
    check(has_diagnostic(csp::assemble("LOOP.i nowhere, =#2, =#1\nNOP\n"), true, "unknown label"),
          "a LOOP naming an unknown label");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#1024, =#1\nNOP\n"), true, "0–1023"), "a count over ten bits");
}

// The firmware builds programs with ProgramBuilder directly: the same
// program built in C++ and assembled from text gives the same image.
void test_builder() {
    using csp::ASource;
    using csp::IndexRegister;
    using csp::Operand;
    using csp::Source;
    csp::ProgramBuilder b;
    const Operand level  = Operand::indexed(IndexRegister::i, 0);
    const Operand rate   = Operand::direct(0x061);
    const Operand target = Operand::direct(0x062);
    b.idx(IndexRegister::i, Source::imm(0x200), Source::reg(Operand::direct(0)));
    const size_t loop = b.open_loop(IndexRegister::i, 4, 16);
    b.add3(level, ASource::result, Source::reg(rate), Source::reg(target));
    b.close_loop(loop);
    const csp::ProgramBuilder::Built built = b.build();
    check(built.ok && built.issues.empty(), "a well-formed built program has no issues");

    const csp::Program text = csp::assemble(R"(
        .equ    VOICES, 0x200
        .reg RATE, 0x061
        .reg TARGET, 0x062
        IDX    i, =#VOICES, 0
        LOOP.i end, =#4, =#16
        ADD3 [i+0], [i+0], RATE, TARGET
end:
)");
    check(text.ok && text.image.rows == built.image.rows && text.image.rom == built.image.rom
                  && text.image.length == built.image.length,
          "the builder and the assembler emit the same image");

    csp::ProgramBuilder bad;
    bad.mac(Operand::indexed(IndexRegister::j, 0), ASource::zero, Source::reg(Operand::direct(1100)),
            Source::reg(Operand::direct(1)));
    (void) bad.open_loop(IndexRegister::i, 1, 1);
    bool reach = false, unclosed = false;
    for (const csp::BuildIssue &found : bad.build().issues) {
        reach    = reach || found.message.find("reaches 0–1023") != std::string::npos;
        unclosed = unclosed || found.message.find("never closed") != std::string::npos;
    }
    check(reach && unclosed, "the builder reports reach, and a loop never closed");
}

// ---- the programs ---------------------------------------------------------------

const char *envelope_program = R"(
        .block VOICE
        .field LEVEL, 2                     ; wide
        .field STAGE, 1                     ; 0 attack, 4 decay, 8 release
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .field U, 1                         ; scratch
        .end
        .block SEGMENT                      ; a row of the envelope table
        .field TARGET, 2                    ; wide
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ    VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060             ; the table's address, raw

        IDX     i, =#VOICES, 0              ; i → voice 0
        LOOP.vi 9, =#2, =#16                ; every voice
        IDX     j, ENV_TABLE, [i+STAGE]     ;   j → this segment's row
        MAX     [i+U], [i+STAGE], =#4       ;   attack → decay, if…
        CMP     ZERO, [i+LEVEL], FULL       ;   …full scale is reached
        SEL     [i+STAGE], [i+U], [i+STAGE] ;   (SEL reads the CMP's flags)
        ANDXOR  [i+U], 0, [i+STAGE], =#4    ;   release → attack: 0/4/8 → 0/4/0
        CMP     ZERO, [i+GATE], FULL        ;   gate held?
        SEL     [i+STAGE], [i+U], =#8       ;     else release
        CMP     [i+U], [j+TARGET], [i+LEVEL]   ;   U ← target − level (the distance)
        MAC.w   [i+LEVEL], [i+U], [j+RATE]     ;   level ← level + U × rate (as envelope.s does it)
)";

void test_envelope() {
    Machine m(envelope_program);
    const int table = 0x200;
    const int voice = 0x600;
    m.processor.write(m.address("ENV_TABLE"), table);
    m.processor.write_wide(table + 0, q_wide(1.3)); // attack → 1.3 × full
    m.processor.write(table + 2, q(0.1));
    m.processor.write_wide(table + 4, q_wide(0.5)); // decay → sustain 0.5
    m.processor.write(table + 6, q(0.05));
    m.processor.write_wide(table + 8, 0); // release → 0
    m.processor.write(table + 10, q(0.05));
    m.processor.write(voice + 3, q(1.0)); // voice 0: gate on
    m.processor.write(voice + 4, q(1.0)); //          velocity 1
    m.processor.write(voice + 16 + 2, 8); // voice 1: idle, in release
    m.start();

    int passes_to_decay = 0;
    double previous     = 0;
    bool rising         = true;
    bool clean          = true;
    for (int pass = 1; pass <= 200 && m.processor.read(voice + 2) == 0; ++pass) {
        clean              = clean && m.run().errors.empty();
        const double level = m.processor.read(voice) / double(csp::word_one);
        rising             = rising && level >= previous;
        previous           = level;
        passes_to_decay    = pass;
    }
    check(clean, "the envelope program runs without early reads");
    check(rising, "attack rises every pass");
    check_equal(m.processor.read(voice + 2), 4, "the attack ends in decay");
    check(passes_to_decay > 5 && passes_to_decay < 30, "the attack takes a plausible number of passes");
    check(previous >= 1.0, "the level reached full scale");
    check_equal(m.processor.read(0x600 + 16 + 2), 8, "voice 1, gate off, sits in release");
    check_equal(m.processor.read(0x600 + 16), 0, "at zero");

    for (int pass = 0; pass < 400; ++pass) m.processor.pass();
    const double sustained = m.processor.read(voice) / double(csp::word_one);
    check(std::abs(sustained - 0.5) < 0.001, "decay settles at the sustain level");

    m.processor.write(voice + 3, 0); // gate off
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 8, "gate off: release");
    for (int pass = 0; pass < 400; ++pass) m.processor.pass();
    check(m.processor.read(voice) < q(0.001), "release falls toward zero");

    m.processor.write(voice + 3, q(1.0)); // gate on again
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 0, "a new gate restarts the attack");
}

void test_lfo() {
    check(has_diagnostic(csp::assemble("SEL r1, =-1.0, =1.0\n"), true, "one immediate"),
          "SEL with two different immediates does not assemble: the square's levels come from registers");
    Machine lfo(R"(
        .wide  PHASE, 0x060
        .wide  RATE, 0x062
        .reg   SAW, 0x064
        .reg   SQUARE, 0x065
        .reg   T, 0x066
        .reg   TRI, 0x067
        .reg   HIGH, 0x068
        .reg   LOW, 0x069
        .const ONE, 1.0
        .const NEG_DEPTH, -1.0
        .const DEPTH_8, 0.125
        .const DEPTH_4, 0.25

        MACW.w  PHASE, ONE, RATE            ; advance and wrap
        MAC     SAW, 0, PHASE, DEPTH_8      ; sawtooth, ±depth
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, LOW, HIGH           ; square, ±depth
        ABS     T, PHASE                    ; 0 … 8
        MAC     TRI, 0, T, DEPTH_4          ; 0 … 2 × depth
        ADD3    TRI, TRI, NEG_DEPTH, ZERO   ; triangle, ±depth
)");
    lfo.set("HIGH", q(1.0)).set("LOW", q(-1.0)).set_wide("RATE", q_wide(16.0 / 8)).start(); // 8 passes per cycle
    int wraps            = 0;
    int32_t previous_saw = 0;
    int32_t lowest       = 0;
    int32_t highest      = 0;
    for (int pass = 0; pass < 16; ++pass) {
        lfo.run();
        const int32_t saw = lfo.get("SAW");
        wraps += saw < previous_saw;
        previous_saw = saw;
        lowest       = std::min(lowest, lfo.get("TRI"));
        highest      = std::max(highest, lfo.get("TRI"));
        check(lfo.get("SQUARE") == (lfo.get("PHASE") < 0 ? q(1.0) : q(-1.0)), "square follows the phase's sign");
    }
    check_equal(wraps, 2, "the saw wraps once per 8 passes");
    check(lowest == q(-1.0) && highest >= q(0.75), "the triangle spans ±depth");
}

// An envelope coefficient (adsr.sv's k, per 96 kHz sample) as a wide rate for a
// 48 kHz pass: the same fraction of the distance in two samples.
void test_envelope_rates() {
    const uint32_t coefficients[] = {1, 7, 100, 250, 1000, 4096, 16384, 65535, 131071, 262143};
    for (const uint32_t k : coefficients) {
        const double sample    = static_cast<double>(k) / (1 << 24);
        const double want      = 1.0 - (1.0 - sample) * (1.0 - sample);
        const double got       = static_cast<double>(csp::envelope_rate(k)) / static_cast<double>(int64_t{1} << 32);
        const std::string name = "k=" + std::to_string(k);
        // within a unit of the rate's last place, 2^-32
        check(std::fabs(got - want) <= 1.0 / static_cast<double>(int64_t{1} << 32),
              name + ": fraction " + std::to_string(got) + ", want " + std::to_string(want));
        check(csp::envelope_rate(k) < (int64_t{1} << 35), name + ": a rate below 8");
    }
    check_equal(csp::envelope_rate(0), 0, "k=0: no movement");
}

// An LFO's old increment as a RATE: the same cycles a second.
void test_lfo_rate() {
    // 1000 per sample at 96 kHz is 1000 / 2^25 of a cycle: 2.861 Hz
    const double old_hertz = 1000.0 * 96000.0 / (1 << 25);
    for (const int passes : {1, 2}) {
        const int64_t rate = csp::lfo_rate(1000, passes);
        const double hertz = static_cast<double>(rate) / static_cast<double>(int64_t{1} << 36) * (48000.0 / passes);
        check(std::fabs(hertz / old_hertz - 1.0) < 1e-12, "lfo_rate: " + std::to_string(passes) + " pass(es) an update");
    }
    check_equal(csp::lfo_rate(0, 2), 0, "lfo_rate: a stopped LFO");
    check(csp::lfo_rate(65535, 2) < (int64_t{1} << 35), "lfo_rate: the fastest LFO is below half a cycle an update");
}

// ---- the control program ----------------------------------------------------

std::string read_program(const char *part) {
    std::ifstream file(std::string("tools/csp/programs/") + part);
    check(static_cast<bool>(file), std::string("reads ") + part);
    std::stringstream text;
    text << file.rdbuf();
    return text.str() + "\n";
}

// tools/csp/programs: the map, the loop counts (the test's own), and the
// parts, joined in order.
std::string control_program(int saws, int squares, int triangles, int sines) {
    std::string source = read_program("map.s");
    source += "        .equ CHANNEL_COUNT, 16\n";
    source += "        .equ VOICE_COUNT, 32\n";
    source += "        .equ SAWS_A_HALF, " + std::to_string(saws) + "\n";
    source += "        .equ SQUARES_A_HALF, " + std::to_string(squares) + "\n";
    source += "        .equ TRIANGLES_A_HALF, " + std::to_string(triangles) + "\n";
    source += "        .equ SINES_A_HALF, " + std::to_string(sines) + "\n";
    for (const char *part : {"lfo.s", "channel.s", "envelope.s", "voice.s"}) source += read_program(part);
    return source;
}

// The self-test program: what the firmware checks at boot, on the model.
void test_selftest_program() {
    Machine m(read_program("map.s") + read_program("selftest.s"));
    m.start();
    // the pass counter's register holds 0 in the first pass after reset (nothing wrote it yet)
    // and the pass's number from the second on; the program sees that value
    int odd_passes = 0;
    for (int pass = 1; pass <= 4; ++pass) {
        const csp::PassReport report = m.run();
        check(report.errors.empty(), "the self-test runs without early reads");
        const int seen = pass == 1 ? 0 : pass;
        const int bit  = seen & 1;
        odd_passes += bit;
        check_equal(m.get("RES_PASS_BIT"), bit, "RES_PASS_BIT follows the pass counter");
        check_equal(m.get("RES_HALF"), bit * 8, "RES_HALF is the bit × 8");
        check_equal(m.get("RES_CHAIN"), bit ? 0x808 : 0x4000, "RES_CHAIN reads the table through IDX");
        check_equal(m.get("RES_ABS"), q(4.0), "ABS of −4.0");
        check_equal(m.get("RES_MAC"), q(0.5), "MAC after it, 4.0 × 0.125");
        check_equal(m.get("RES_ADD3"), q(-3.5), "ADD3 after that, 0.5 − 4.0");
        check_equal(m.get("RES_SEL"), q(0.125), "SEL after a CMP");
        check_equal(m.get("COUNT_TOTAL"), pass, "COUNT_TOTAL counts the passes");
        check_equal(m.get("COUNT_PASSES"), pass, "COUNT_PASSES, which wraps, counts them too");
        check_equal(m.get("PASS_VIA_LOGIC"), seen, "the logic unit's copy of the pass counter");
        check_equal(m.get("PASS_VIA_DSP"), seen, "the multiply-add's copy");
        check_equal(m.get("PASS_VIA_LOGIC_A"), seen, "the logic unit's second copy");
        check_equal(m.get("PASS_VIA_LOGIC_B"), seen, "and its third");
    }
    check_equal(m.get("COUNT_ODD"), odd_passes, "COUNT_ODD counts the odd passes");
    check_equal(m.get("COUNT_HALF_ODD"), odd_passes, "COUNT_HALF_ODD agrees");
    check_equal(m.get("COUNT_CHAIN_ODD"), odd_passes, "COUNT_CHAIN_ODD agrees");
}

// The whole program on 16 channels and 32 voices, every one different. The
// envelopes' rates are 0, so their levels stay where they are set, and the
// LFOs' outputs are set directly (with no LFO in the loops), so that every
// sink has a value to check against the formulas in voice.s and channel.s.
void test_control_program() {
    Machine m(control_program(0, 0, 0, 0));
    csp::Processor &cpu    = m.processor;
    const int channels     = m.address("CHANNELS");
    const int voices       = m.address("VOICES");
    const int sinks        = m.address("SINKS");
    const int lfos         = m.address("LFOS");
    const int channel_size = m.address("CHANNEL_SIZE");
    const int voice_size   = m.address("VOICE_SIZE");
    const int lfo_size     = m.address("LFO_SIZE");
    const int lfo_count    = 2 * m.address("LFOS_A_HALF");
    auto at                = [&](int base, const char *field) { return base + m.address(field); };

    // the LFOs, with outputs between -1 and 1
    std::vector<double> lfo_out(static_cast<size_t>(lfo_count));
    for (int k = 0; k < lfo_count; ++k) {
        lfo_out[static_cast<size_t>(k)] = std::sin(0.7 * k);
        cpu.write(at(lfos + k * lfo_size, "OUT"), q(lfo_out[static_cast<size_t>(k)]));
    }
    for (int half = 0; half < 2; ++half) {
        cpu.write(at(m.address("LFO_SETS") + half * m.address("SET_SIZE"), "BASE"),
                  lfos + half * m.address("LFOS_A_HALF") * lfo_size);
    }
    struct Channel {
        double bend, p1, c1, p2, c2, base, track, amount;
        int lfo1, lfo2;
        double d1, d2, r1, r2, duty0, duty1, resonance; // the pulse width and Q
    };
    const int channel_sinks = m.address("CHANNEL_SINKS");
    const int sink_size     = m.address("CHANNEL_SINK_SIZE");
    std::vector<Channel> channel(16);
    for (int c = 0; c < 16; ++c) {
        channel[c]     = {0.02 * (c - 8),  0.1 + 0.01 * c,   -0.2 + 0.03 * c,
                          0.05 * (c % 4),  0.4 - 0.02 * c,   0.5 + 0.1 * (c % 5),
                          0.25 * (c % 5),  0.3 + 0.05 * c,
                          (3 * c) % lfo_count, (7 * c + 5) % lfo_count, 0.03 * (c % 5),
                          -0.02 * (c % 3), 0.1 * (c % 4),    0.05 * (c % 6),
                          0.1 + 0.02 * c,  -0.3 + 0.03 * c,  0.5 + 0.1 * (c % 7)};
        const int base = channels + c * channel_size;
        cpu.write(at(base, "LFO1_DUTY"), q(channel[c].d1));
        cpu.write(at(base, "LFO2_DUTY"), q(channel[c].d2));
        cpu.write(at(base, "LFO1_RESONANCE"), q(channel[c].r1));
        cpu.write(at(base, "LFO2_RESONANCE"), q(channel[c].r2));
        cpu.write(at(base, "DUTY_BASE_0"), q(channel[c].duty0));
        cpu.write(at(base, "DUTY_BASE_1"), q(channel[c].duty1));
        cpu.write(at(base, "RESONANCE_BASE"), q(channel[c].resonance));
        cpu.write(at(base, "SINK_BLOCK"), channel_sinks + c * sink_size);
        cpu.write(at(base, "BEND"), q(channel[c].bend));
        cpu.write(at(base, "LFO1_PITCH"), q(channel[c].p1));
        cpu.write(at(base, "LFO1_CUTOFF"), q(channel[c].c1));
        cpu.write(at(base, "LFO2_PITCH"), q(channel[c].p2));
        cpu.write(at(base, "LFO2_CUTOFF"), q(channel[c].c2));
        cpu.write(at(base, "CUTOFF_BASE"), q(channel[c].base));
        cpu.write(at(base, "KEY_TRACK"), q(channel[c].track));
        cpu.write(at(base, "MOD_AMOUNT"), q(channel[c].amount));
        cpu.write(at(base, "LFO1"), lfos + channel[c].lfo1 * lfo_size);
        cpu.write(at(base, "LFO2"), lfos + channel[c].lfo2 * lfo_size);
    }
    struct Voice {
        double note, level_a, level_m, velocity;
        int channel;
    };
    std::vector<Voice> voice(32);
    for (int v = 0; v < 32; ++v) {
        voice[v]       = {-1.0 + 0.1 * v, 0.1 + 0.02 * v, 0.9 - 0.02 * v, 0.3 + 0.02 * v, (5 * v + 1) % 16};
        const int base = voices + v * voice_size;
        cpu.write(at(base, "NOTE"), q(voice[v].note));
        cpu.write_wide(at(base, "LEVEL_A"), q_wide(voice[v].level_a));
        cpu.write_wide(at(base, "LEVEL_M"), q_wide(voice[v].level_m));
        cpu.write(at(base, "VELOCITY"), q(voice[v].velocity));
        cpu.write(at(base, "VELOCITY_M"), q(1.0));
        cpu.write(at(base, "GATE"), q(1.0));
        cpu.write(at(base, "STAGE_A"), 4); // decay row: rate 0
        cpu.write(at(base, "STAGE_M"), 20);
        cpu.write(at(base, "CHANNEL"), channels + voice[v].channel * channel_size);
        cpu.write(at(base, "SINK"), sinks + v * 8);
    }
    m.start();
    // two passes: the second sees the channel values the first computed
    m.run();
    if (std::getenv("CSP_TRACE")) cpu.trace(true);
    const csp::PassReport report = m.run();
    check(report.errors.empty(), "the control program runs without errors");
    check(report.stale_sinks.empty(), "every sink is written every pass");
    check(report.cycles <= csp::pass_cycle_limit, "the control program fits a pass: " + std::to_string(report.cycles));
    check_equal(report.cycles, m.program.cycles, "the model counts the cycles the assembler scheduled");
    std::printf("control program (no LFOs in the loops): %d cycles a pass, %d rows\n", report.cycles,
                m.program.image.length);

    // the formulas; the program's sinks are those published at the pass's end
    double worst = 0;
    for (int v = 0; v < 32; ++v) {
        const Voice &a         = voice[v];
        const Channel &c       = channel[a.channel];
        const double ch_pitch  = c.bend + lfo_out[c.lfo1] * c.p1 + lfo_out[c.lfo2] * c.p2;
        const double ch_cutoff = c.base + lfo_out[c.lfo1] * c.c1 + lfo_out[c.lfo2] * c.c2 + c.track * ch_pitch;
        // the gain sink is the amp envelope's level × velocity, the fraction of
        // the pipeline's span: the pipeline takes the exponential
        const double want[3]   = {a.note + ch_pitch, 4 * a.level_m * c.amount + a.note * c.track + ch_cutoff,
                                  a.level_a * a.velocity};
        const char *const fields[3] = {"SINK_PITCH", "SINK_CUTOFF", "SINK_GAIN"};
        for (int k = 0; k < 3; ++k) {
            const int offset = (sinks - csp::sink_base) + v * 8 + m.address(fields[k]);
            const double got = cpu.sink(offset) / 16384.0;
            worst            = std::max(worst, std::fabs(got - want[k]));
        }
    }
    // a few raw units of the words' rounding, through up to seven operations
    check(worst <= 24.0 / 16384.0, // the mod envelope's term is multiplied by 4
          "the voices' sinks match their formulas: largest difference " + std::to_string(worst));

    // the channels' own sinks: the pulse widths and the resonance
    double worst_channel = 0;
    for (int c = 0; c < 16; ++c) {
        const Channel &a            = channel[c];
        const double duty           = lfo_out[a.lfo1] * a.d1 + lfo_out[a.lfo2] * a.d2;
        const double reso           = lfo_out[a.lfo1] * a.r1 + lfo_out[a.lfo2] * a.r2;
        const double want[3]        = {a.duty0 + duty, a.duty1 + duty, a.resonance + reso};
        const char *const fields[3] = {"DUTY_0", "DUTY_1", "RESONANCE"};
        for (int k = 0; k < 3; ++k) {
            const int offset = (channel_sinks - csp::sink_base) + c * sink_size + m.address(fields[k]);
            worst_channel    = std::max(worst_channel, std::fabs(cpu.sink(offset) / 16384.0 - want[k]));
        }
    }
    check(worst_channel <= 6.0 / 16384.0,
          "the channels' duty and resonance sinks match their formulas: largest difference "
                  + std::to_string(worst_channel));
}

// The LFOs in their worst case, all sines, as many a half as fit a pass
// beside 16 channels and 32 voices (the budget #237's generator works to;
// the full half is reported): each LFO updates once in two passes.
constexpr int sines_that_fit = 12;
void test_control_program_lfos() {
    {
        // the full half of sines, as a finding: how far over or under the pass it is
        const csp::Program full = csp::assemble(control_program(0, 0, 0, 12));
        std::string verdict     = full.ok ? "fits a pass at " + std::to_string(full.cycles) + " cycles" : "does not fit a pass:";
        for (const csp::Diagnostic &d : full.diagnostics) {
            if (d.error) verdict += " " + d.message;
        }
        std::printf("control program (12 sine LFOs a pass, 16 channels, 32 voices): %s\n", verdict.c_str());
    }
    Machine m(control_program(0, 0, 0, sines_that_fit));
    csp::Processor &cpu = m.processor;
    const int lfos      = m.address("LFOS");
    const int lfo_size  = m.address("LFO_SIZE");
    const int a_half    = sines_that_fit;   // records a half in the loops; the pool holds LFOS_A_HALF
    const int set_size  = m.address("SET_SIZE");
    const int sets      = m.address("LFO_SETS");
    auto at             = [&](int base, const char *field) { return base + m.address(field); };
    for (int half = 0; half < 2; ++half) {
        cpu.write(at(sets + half * set_size, "BASE"), lfos + half * m.address("LFOS_A_HALF") * lfo_size);
    }
    // the pointers, so that no two voices or channels share a register
    const int channels      = m.address("CHANNELS");
    const int voices        = m.address("VOICES");
    const int sinks         = m.address("SINKS");
    const int channel_size  = m.address("CHANNEL_SIZE");
    const int voice_size    = m.address("VOICE_SIZE");
    const int channel_sinks = m.address("CHANNEL_SINKS");
    const int sink_size     = m.address("CHANNEL_SINK_SIZE");
    for (int c = 0; c < 16; ++c) {
        const int base = channels + c * channel_size;
        cpu.write(at(base, "LFO1"), lfos + ((3 * c) % (2 * a_half)) * lfo_size);   // any record: only OUT is read
        cpu.write(at(base, "LFO2"), lfos + ((7 * c + 5) % (2 * a_half)) * lfo_size);
        cpu.write(at(base, "SINK_BLOCK"), channel_sinks + c * sink_size);
    }
    for (int v = 0; v < 32; ++v) {
        const int base = voices + v * voice_size;
        cpu.write(at(base, "CHANNEL"), channels + ((5 * v + 1) % 16) * channel_size);
        cpu.write(at(base, "SINK"), sinks + v * 8);
        cpu.write(at(base, "STAGE_A"), 4);
        cpu.write(at(base, "STAGE_M"), 20);
    }
    const int pool_half = m.address("LFOS_A_HALF");
    auto record_of      = [&](int k) { return lfos + ((k / a_half) * pool_half + k % a_half) * lfo_size; };
    const double step   = 0.01; // of a cycle an update
    for (int k = 0; k < 2 * a_half; ++k) {
        const int record = record_of(k);
        cpu.write_wide(at(record, "PHASE_STEP"), q_wide(step * 16.0));
        cpu.write(at(record, "DEPTH"), q(1.0));
    }
    m.start();
    int worst = 0;
    for (int pass = 1; pass <= 4; ++pass) {
        const csp::PassReport report = m.run();
        worst                        = std::max(worst, report.cycles);
        check(report.errors.empty(), "the control program with LFOs runs without errors");
    }
    std::printf("control program (%d sine LFOs a pass): %d cycles a pass, %d rows\n", a_half, worst,
                m.program.image.length);
    check(worst <= csp::pass_cycle_limit, "the control program with the sines fits a pass: " + std::to_string(worst));
    check_equal(worst, m.program.cycles, "the model counts the cycles the assembler scheduled");
    // each half updates in the passes whose pass counter has its parity: the counter's register
    // reads 0 in the first pass after reset and the pass's number from then on (0, 2, 3, 4), so
    // the even half updated three times and the odd half once
    int updates[2] = {0, 0};
    for (int pass = 1; pass <= 4; ++pass) updates[(pass == 1 ? 0 : pass) & 1]++;
    for (int k = 0; k < 2 * a_half; ++k) {
        const int64_t phase = cpu.read_wide(at(record_of(k), "PHASE"));
        check_equal(phase, updates[k / a_half] * q_wide(step * 16.0),
                    "LFO " + std::to_string(k) + " updated " + std::to_string(updates[k / a_half]) + " times");
    }
}

} // namespace

int main() {
    test_encoding();
    test_mac();
    test_macw_and_wide();
    test_add3_sel_cmp_min_max();
    test_andxor_shift_abs_nop();
    test_schedule();
    test_index();
    test_loops();
    test_vector_loops();
    test_empty_inner_loop_at_outer_end();
    test_decisions();
    test_queue_and_swap();
    test_hold();
    test_limits();
    test_sinks();
    test_firmware_sinks();
    test_assembler();
    test_labels_and_count();
    test_builder();
    test_envelope();
    test_lfo();
    test_envelope_rates();
    test_lfo_rate();
    test_selftest_program();
    test_control_program();
    test_control_program_lfos();
    std::printf("csp: %s (%d checks, %d failures)\n", failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
