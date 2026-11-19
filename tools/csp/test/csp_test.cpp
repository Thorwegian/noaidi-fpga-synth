// csp_test.cpp — host tests for the CSP reference model, builder and assembler
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every instruction at its edges (formats, truncation, saturation, wrap,
// flags), the rules a program can see (the index registers, loops,
// the write queue and swap, the hold, pass limits, sink pages), the
// schedule the builder lays out (checked by the model's scoreboard), the
// assembler's checks, and the boot self-test (app/main/csp/selftest.cpp).
//
//   make csp-test

#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "../assembler.hpp"
#include "../processor.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "csp/program_builder.hpp"
#include "csp/selftest.hpp"

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
        std::printf("FAIL %s: got %lld, want %lld\n", what.c_str(),
                    static_cast<long long>(got), static_cast<long long>(want));
        ++failures;
    }
}

int32_t q(double value) {
    return static_cast<int32_t>(std::llround(value * csp::word_one));
}

int64_t q_wide(double value) {
    return std::llround(
            value * static_cast<double>(int64_t{1} << csp::wide_fraction_bits));
}

// A program assembled and loaded on a fresh processor, with any register
// values set while the CSP is held.
class Machine {
public:
    explicit Machine(std::string_view source) : program(csp::assemble(source)) {
        for (const csp::Diagnostic &d : program.diagnostics) {
            if (d.error) {
                std::printf("  assembly error, line %d: %s\n", d.line,
                            d.message.c_str());
            }
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
        while (processor.queued_writes() > 0) {
            processor.pass();
        }
        check(processor.load(program.image), "program loads while held");
        processor.release();
        return *this;
    }

    // A pass; the model's errors are test failures.
    csp::PassReport run() {
        const csp::PassReport report = processor.pass();
        for (const std::string &error : report.errors) {
            std::printf("  model: %s\n", error.c_str());
        }
        return report;
    }

    int32_t get(const std::string &name) const {
        return processor.read(address(name));
    }
    int64_t get_wide(const std::string &name) const {
        return processor.read_wide(address(name));
    }

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

bool has_diagnostic(const csp::Program &program, bool error,
                    std::string_view text) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        if (d.error == error && d.message.find(text) != std::string::npos) {
            return true;
        }
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
    check_equal(report.cycles, m.program.cycles,
                "the model counts the cycles the assembler scheduled");
    return report.cycles
           - 1; // the instructions' own cycles: the END row's issue (#271) left out
}

// ---- encoding ---------------------------------------------------------------

void test_encoding() {
    using csp::Operand;
    csp::Word word;
    word.op            = 0x5A;
    word.cond          = static_cast<uint8_t>(csp::Condition::negative);
    word.r             = Operand::indexed(csp::IndexRegister::i, 0);
    word.x             = Operand::indexed(csp::IndexRegister::j, 2);
    word.y             = Operand::direct(0x3FF);
    word.imm           = 0x3FFFD;
    const csp::Row row = word.encode();
    check(row.high < (uint64_t{1} << 36) && row.low < (uint64_t{1} << 36),
          "a row is two 36-bit dwords");
    check(csp::Word::decode(row) == word,
          "a word encodes and decodes round-trip");
    check_equal(static_cast<int64_t>(row.high >> 28), 0x5A, "op is bits 71:64");
    check(csp::Word::decode(csp::Row{}).op == 0,
          "an all-zero row is op 0, the NOP");
    check(Operand::decode(0x805) == Operand::indexed(csp::IndexRegister::j, 5),
          "operand 10 0000000101 is j|5");
    check(Operand::decode(0x0FF) == Operand::direct(0xFF),
          "operand 00 0011111111 is direct 255");
    check(Operand::decode(0xC00).mode == Operand::Mode::immediate,
          "mode 3 is an immediate");

    csp::Control control{csp::Unit::multiply_add,
                         csp::Writes::pair,
                         csp::ASource::result,
                         true,
                         true,
                         csp::ConditionKind::flags,
                         true,
                         true,
                         0};
    check(csp::Control::decode(control.encode()) == control,
          "a control word encodes and decodes round-trip");
    check_equal(
            csp::control_of(csp::Op::nop, false, csp::ASource::zero).encode(),
            0, "NOP's control word is 0");
    // which operands a row reads: the chip parks the read ports of the others
    const auto reads = [](csp::Op op) {
        const csp::Control c = csp::control_of(op, false, csp::ASource::zero);
        return (c.reads_x ? 1 : 0) | (c.reads_y ? 2 : 0);
    };
    check_equal(reads(csp::Op::mac), 3, "MAC reads X and Y");
    check_equal(reads(csp::Op::abs), 1, "ABS reads X only");
    check_equal(reads(csp::Op::shift), 2, "SHIFT reads Y only (X is not read)");
    check_equal(reads(csp::Op::idx), 3, "IDX reads X and Y");
    check_equal(reads(csp::Op::loop), 0,
                "LOOP reads nothing: its numbers are in the word");
    check_equal(reads(csp::Op::nop), 0, "NOP reads nothing");
    check_equal(reads(csp::Op::end), 0, "END reads nothing");
    check(csp::control_of(csp::Op::end, false, csp::ASource::zero).encode()
                  != 0,
          "END's control word is not NOP's: the fetch tells them apart");
    check(csp::mnemonic(csp::Op::end) == "END", "END has its mnemonic");
    // CMP's row alone has "set the flags"; SUB is the same row without it
    using csp::ConditionKind;
    using csp::Op;
    for (const Op op : {Op::mac, Op::macw, Op::add3, Op::sub, Op::abs, Op::min,
                        Op::max, Op::andxor, Op::shift}) {
        check(csp::control_of(op, false, csp::ASource::zero).cond
                      == ConditionKind::none,
              std::string(csp::mnemonic(op)) + " leaves the flags");
    }
    csp::Control compare = csp::control_of(Op::cmp, false, csp::ASource::zero);
    check(compare.cond == ConditionKind::flags, "CMP sets the flags");
    compare.cond = ConditionKind::none;
    check(compare == csp::control_of(Op::sub, false, csp::ASource::zero),
          "SUB is CMP's control word with the condition kind none");
}

// ---- arithmetic ---------------------------------------------------------------

const char *registers = R"(
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .dword W_, 0x064
        .dword V_, 0x066
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

    Machine tiny(std::string(registers) + R"(
        MAC   A_, 0, B_, B_
        MAC   C_, 0, B_, D_
)");
    tiny.set("B_", 1).set("D_", -1).start().run();
    check_equal(tiny.get("A_"), 0, "MAC truncates 2⁻²⁸ to 0");
    check_equal(tiny.get("C_"), -1,
                "MAC truncates −2⁻²⁸ toward minus infinity");
}

void test_macw_and_wide() {
    Machine m(std::string(registers) + R"(
        .const ONE, 1.0
        MACW  A_, A_, B_, ONE
        MACW.d W_, ONE, V_
)");
    m.set("A_", q(7.5)).set("B_", q(1.0));
    m.set_wide("W_", q_wide(7.75)).set_wide("V_", q_wide(0.5)).start().run();
    check_equal(m.get("A_"), q(-7.5), "MACW wraps 7.5 + 1.0 to −7.5");
    check_equal(m.get_wide("W_"), q_wide(-7.75), "MACW.d wraps a dword phase");
    check_equal(m.get("W_"), q(-7.75), "a dword's upper word reads as Q4.14");
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

    // CMP alone sets the flags: rows of every other kind between it and its
    // SEL, with results of the other sign, and one that saturates
    Machine between(std::string(registers) + R"(
        CMP   ZERO, B_, C_          ; 1 − 2: negative
        MAC   A_, 0, C_, C_
        ADD3  A_, 0, C_, C_
        ABS   A_, C_
        MAX   A_, B_, C_
        MIN   A_, B_, C_
        SUB   W_, C_, B_            ; 2 − 1, the flags left
        SHIFT A_, A_, =#1
        ANDXOR A_, 0, B_, C_
        MACW  A_, A_, C_, C_
        MAC   V_, 0, =7.0, =7.0     ; saturates
        SEL   D_, B_, C_            ; by the CMP: negative, Y
)");
    between.set("B_", q(1.0)).set("C_", q(2.0)).start();
    const csp::PassReport between_report = between.run();
    check(between_report.errors.empty(),
          "rows between a CMP and its SEL run without an early read");
    check_equal(between.get("D_"), q(2.0),
                "SEL chooses by the CMP, whatever rows stand between");
    check_equal(between.get("W_"), q(1.0), "SUB: 2 − 1");
    check(between.processor.flags().negative
                  && !between.processor.flags().overflow,
          "the flags are the CMP's still: no other row sets them");

    Machine over(std::string(registers) + "CMP A_, B_, C_\n");
    over.set("B_", q(7.0)).set("C_", q(-7.0)).start().run();
    check_equal(over.get("A_"), csp::largest(18), "CMP saturates");
    check(over.processor.flags().overflow,
          "CMP sets V when the difference saturates");
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
    check_equal(m.get("D_"), -(q(1.0) / 8) - 1,
                "SHIFT right by 3 truncates toward minus infinity");
    check_equal(m.get("W_"), csp::largest(18),
                "ABS of −8 saturates to just under +8");
    check(!m.processor.flags().negative && !m.processor.flags().zero,
          "NOP leaves the flags of the CMP before it");

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
    const auto cycles = [](std::string_view body) {
        return cycles_of(std::string(registers) + std::string(body));
    };
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC B_, 0, =1.0, =1.0\n"), 2,
                "independent instructions issue every cycle");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC B_, 0, A_, =1.0\n"),
                csp::result_latency + 1, "a read of R waits for its write");
    check_equal(
            cycles(".reg W_LOWER, 0x065\nMAC.d W_, =1.0, V_\nMAC B_, 0, W_LOWER, =1.0\n"),
            csp::result_latency + 1,
            "a read of a pair's lower word waits for the dword write");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nMAC C_, 0, B_, =1.0\n"), 2,
                "another register does not wait");
    check_equal(cycles("CMP ZERO, A_, =1.0\nSEL B_, =1.0, C_\n"),
                csp::state_latency + 1, "SEL waits for the flags of a CMP");
    check_equal(
            cycles("CMP ZERO, A_, =1.0\nMAC D_, 0, =1.0, =1.0\nSUB D_, A_, C_\nSEL B_, =1.0, C_\n"),
            csp::state_latency + 1,
            "other rows stand between a CMP and its SEL at no cost");
    check_equal(cycles("MAC A_, 0, =1.0, =1.0\nSEL B_, =1.0, C_\n"), 2,
                "SEL does not wait for a row that is not a CMP");
    check_equal(
            cycles("IDX i, =#0x100, 0\nMAC [i+1], 0, =1.0, =1.0\n"),
            csp::index_latency + 1,
            "a row that uses the index comes index_latency cycles behind its IDX");
    check_equal(cycles("IDX i, =#0x100, 0\nMAC B_, 0, =1.0, =1.0\n"), 2,
                "a row that uses no index does not wait for an IDX");
    check_equal(cycles("IDX i, =#0x100, 0\nMAC [j+1], 0, =1.0, =1.0\n"), 2,
                "nor does a row that uses the other index register");
    check_equal(
            cycles("IDX i, =#0x100, 0\nLOOP.j end, =#2, =#1\nMAC B_, 0, =1.0, =1.0\nend:\n"),
            csp::index_latency + 1 + 2 + csp::jump_penalty,
            "a loop row waits for an IDX in flight");
    check_equal(
            cycles("MAC A_, 0, =1.0, =1.0\nNOP\nNOP\nNOP\nNOP\nNOP\nNOP\nMAC B_, 0, A_, =1.0\n"),
            csp::result_latency + 1,
            "a program's own NOPs count toward the wait");
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
    check_equal(m.processor.read(0x101), q(1.0),
                "the instruction after IDX sees the new i");
    check_equal(m.processor.read(0x182), q(4.0),
                "and again after the second IDX");
    check_equal(m.processor.read(0x231), q(0.25),
                "IDX adds X and Y; the offset ORs in");
    check_equal(m.processor.index(csp::IndexRegister::j), 0x230,
                "j holds the sum");
    check(report.errors.empty(), "without an early read");

    // Rows in an IDX's wait: those that use the other index register, or none.
    Machine filled(std::string(registers) + R"(
        IDX   i, =#0x100, 0
        IDX   j, =#0x200, 0             ; in i's wait
        MAC   A_, 0, =0.5, =0.5         ; in both
        MAC   [i+1], 0, =1.0, =1.0      ; i has landed
        MAC   [j+1], 0, =2.0, =2.0      ; j has landed
        IDX   i, =#0x180, 0
        MAC   [j+2], 0, =1.5, =1.5      ; in i's wait, through j
        MAC   [i+2], 0, =0.5, =0.5
)");
    filled.start();
    const csp::PassReport filled_report = filled.run();
    check(filled_report.errors.empty(),
          "rows in an IDX's wait run without an early read");
    // IDX i, IDX j, MAC, two waits, the two users, IDX i, a row through j,
    // three waits, i's user, END
    check_equal(filled.program.cycles, 2 * csp::index_latency + 4,
                "only the rows that use an index wait for it");
    check_equal(filled_report.cycles, filled.program.cycles,
                "the model counts the cycles the assembler scheduled");
    check_equal(filled.processor.read(0x060), q(0.25), "the row in both waits");
    check_equal(filled.processor.read(0x101), q(1.0), "i's first user");
    check_equal(filled.processor.read(0x201), q(4.0), "j's user");
    check_equal(filled.processor.read(0x202), q(2.25),
                "the row through j in i's second wait");
    check_equal(filled.processor.read(0x182), q(0.25), "i's second user");

    // The chip ORs the offset into the index: an offset whose bits the
    // index already has is a different address from the sum, and reported.
    Machine overlap(std::string(registers)
                    + "IDX i, =#0x204, 0\nMAC [i+4], 0, =1.0, =1.0\n");
    overlap.start();
    const csp::PassReport overlap_report = overlap.processor.pass();
    check(overlap_report.errors.size() == 1
                  && overlap_report.errors[0].find("overlap")
                             != std::string::npos,
          "an offset overlapping the index's bits is reported");
    check_equal(overlap.processor.read(0x204), q(1.0),
                "and the chip's OR is what the model did");
}

// LOOP.vi runs its body instruction by instruction across all elements,
// in rounds of sixteen: the same results as LOOP.i when iterations are
// independent, with fewer waits; per-element flags and j; shared
// registers reported.
void test_vector_loops() {
    const std::string body      = R"(
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
    auto make                   = [&](const char *loop) {
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
    check(vector->program.diagnostics.empty() && vector_report.errors.empty(),
          "a vector loop assembles and runs");
    check(scalar_report.errors.empty(), "the scalar loop runs");
    bool same = true;
    for (int address = 0x200; address < 0x240; ++address) {
        same = same
               && scalar->processor.read(address)
                          == vector->processor.read(address);
    }
    check(same, "LOOP.vi gives LOOP.i's results");
    check_equal(vector->processor.read(0x200 + 2), q(-0.25),
                "SEL sees its own element's flags (negative: Y)");
    check_equal(vector->processor.read(0x200 + 8 + 2), q(1.0),
                "and the next element's (positive: X)");
    check_equal(vector->processor.read(0x200 + 8 * 5 + 4), q(0.625),
                "an element's [j+…] uses its own j");
    check_equal(vector->processor.index(csp::IndexRegister::j), 0x307,
                "after the loop, j is the last element's");
    // IDX and its wait rows, LOOP.vi, then the body's rows for each of the 8 elements, the
    // one bubble behind the first element. A dependent pair of rows is ceil(latency / elements) rows
    // apart: the MAC and the CMP that reads its result, and the IDX after the SEL (inside a
    // vector loop the index's base is unknown, so an indexed read waits for every earlier
    // indexed write).
    const int spacing_8 = (csp::result_latency + 7) / 8;
    check_equal(
            vector_report.cycles,
            csp::index_latency + 1 + 1 + (5 + 2 * (spacing_8 - 1)) * 8
                    + 1, // + END's issue
            "a vector loop of 8 elements: dependent rows ceil(latency / 8) apart, one bubble to enter, nothing else");
    check(scalar_report.cycles > vector_report.cycles,
          "the scalar loop waits inside each iteration");

    // Two elements a round: a dependent row is ceil(latency / 2) rows on.
    Machine two(body + "        LOOP.vi 2, =#2, =#8\n"
                + "        MAC [i+DOUBLE], 0, [i+X], =2.0\n"
                + "        MAC [i+PICK], 0, [i+DOUBLE], =1.0\n");
    two.start();
    const csp::PassReport two_report = two.run();
    check(two_report.errors.empty(),
          "a two-element loop is spaced by the latency");
    const int spacing_2 = (csp::result_latency + 1) / 2;
    check_equal(two_report.cycles,
                csp::index_latency + 1 + 1 + (2 + (spacing_2 - 1)) * 2
                        + 1, // + END's issue
                "ceil(latency / 2) - 1 wait rows between the dependent pair");

    Machine shared(body
                   + "        .reg T, 0x060\n"
                     "        LOOP.vi 2, =#8, =#8\n"
                     "        MAC T, 0, [i+X], =1.0\n"
                     "        MAC [i+PICK], 0, T, =1.0\n");
    shared.start();
    check(!shared.processor.pass().errors.empty(),
          "elements sharing a register are reported");
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
        check_equal(m.processor.read(0x200 + 16 * block), q(1.0),
                    "LOOP.i writes block " + std::to_string(block));
    }
    check_equal(m.processor.read(0x200 + 16 * 4), 0, "and no further");
    check_equal(m.processor.read(0x300), q(1.0),
                "nested loop: j+0 on the first outer pass");
    check_equal(m.processor.read(0x302), q(1.0),
                "j steps 3 times per inner loop");
    check_equal(m.processor.read(0x303), q(1.0),
                "and carries on in the second outer pass");
    check_equal(m.processor.read(0x305), q(1.0), "6 inner passes in all");
    check_equal(m.processor.read(0x306), 0, "and no more");
    check_equal(m.get("A_"), 0, "a count of 0 skips the body");
    check_equal(m.get("B_"), q(1.0), "and the program continues after it");
    check(report.errors.empty(), "loops run without errors");
    check_equal(report.cycles, m.program.cycles,
                "the model counts the cycles the assembler scheduled");

    // A loop whose body reads what its previous iteration wrote: the
    // schedule has the wait, so the second iteration reads the result.
    Machine chain(std::string(registers) + R"(
        LOOP.i 1, =#3, =#0
        ADD3   A_, A_, =1.0, ZERO
)");
    chain.start();
    const csp::PassReport chain_report = chain.run();
    check_equal(chain.get("A_"), q(3.0),
                "an accumulating loop body sees its own result");
    check(chain_report.errors.empty(),
          "because the schedule waits between iterations");
    check(chain_report.cycles >= 1 + 3 * 1 + 2 * (csp::result_latency - 1),
          "at the cost of the latency each time");
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
    check_equal(m.processor.index(csp::IndexRegister::j), 3,
                "the outer loop stepped j three times");
    check(report.errors.empty(), "without errors");
}

// The chip has no stall, so a wait is rows: a row that uses an index stands
// index_latency rows behind its IDX, with NOPs between when nothing else can
// issue; and a loop of count 0 is not there at all.
void test_decisions() {
    const csp::Program idx =
            csp::assemble(std::string(registers)
                          + "IDX i, =#0x100, 0\nMAC [i+1], 0, =1.0, =1.0\n");
    check(idx.ok, "IDX assembles");
    check_equal(
            idx.image.length, 1 + (csp::index_latency - 1) + 1 + 1,
            "an IDX and its user are index_latency - 1 NOP rows apart (and the image ends with END)");
    for (int row = 1; row < csp::index_latency; ++row) {
        check(csp::Word::decode(idx.image.rows[static_cast<size_t>(row)]).op
                      == 0,
              "the row between an IDX and its only user is a NOP");
    }
    const csp::Program filled = csp::assemble(
            std::string(registers)
            + "IDX i, =#0x100, 0\nMAC A_, 0, =1.0, =1.0\nMAC [i+1], 0, =1.0, =1.0\n");
    check_equal(filled.image.length, 1 + (csp::index_latency - 1) + 1 + 1,
                "a row that uses no index takes the place of a NOP");
    check(csp::Word::decode(filled.image.rows[1]).op != 0,
          "and it is the row behind the IDX");

    const csp::Program without =
            csp::assemble(std::string(registers) + "MAC A_, 0, =1.0, =1.0\n");
    const csp::Program with_empty = csp::assemble(
            std::string(registers)
            + "LOOP.i end, =#0, =#1\nMAC B_, 0, =2.0, =2.0\n"
              "LOOP.j end2, =#0, =#1\nMAC D_, 0, =4.0, =4.0\nMAC C_, 0, =3.0, =3.0\n"
              "end2:\nend:\nMAC A_, 0, =1.0, =1.0\n");
    check(with_empty.ok, "loops of count 0 assemble");
    check(with_empty.image.rows == without.image.rows
                  && with_empty.image.length == without.image.length,
          "a loop of count 0 and its body, nested loops and all, leave no row");
    check_equal(with_empty.cycles, without.cycles, "and cost no cycle");

    check(has_diagnostic(
                  csp::assemble(
                          "LOOP.i end, =#2, =#1\nIDX i, =#0x200, 0\nend:\nNOP\n"),
                  true, "own index register"),
          "a loop body cannot set its own index register");
    check(csp::assemble(
                  std::string(registers)
                  + "LOOP.i end, =#2, =#1\nIDX j, =#0x200, 0\nend:\nNOP\n")
                  .ok,
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
    check_equal(m.get("A_"), q(1.0),
                "after the swap, the window applies it at the end of the pass");
    check_equal(m.get("B_"), 0, "so the pass itself never saw it");
    m.run();
    check_equal(m.get("B_"), q(1.0), "the next pass does");

    for (int n = 0; n < 60; ++n) {
        m.processor.write(0x100 + n, q(1.0));
    }
    m.processor.swap();
    const csp::PassReport first = m.run();
    check_equal(first.writes_applied, csp::write_window,
                "the window applies 48 writes per pass");
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
    check(!m.processor.load(m.program.image),
          "a program does not load while running");
}

void test_limits() {
    std::string source;
    for (int n = 0; n < csp::program_rows + 1; ++n) {
        source += "NOP\n";
    }
    check(has_diagnostic(csp::assemble(source), true, "IMEM holds"),
          "the assembler rejects a program over 1472 rows");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#1023, =#0\nNOP\n"), true,
                         "the pass runs"),
          "the assembler rejects a pass over 1472 cycles");
    // 256 distinct control words would need more decode rows than the op
    // field reaches; the program's variants come to a handful
    const csp::Program program = csp::assemble(
            std::string(registers) + "MAC A_, 0, B_, C_\nMAC.d W_, B_, V_\n"
            + "SEL A_, B_, C_\nIDX i, =#0x100, 0\nIDX j, =#0x100, 0\n");
    check_equal(
            program.image.rom_used, csp::rom_reserved + 5 + 1,
            "distinct control words get a decode row each, after the NOP's and the vector loops' (IDX i and IDX j differ; END's row is the sixth)");
}

void test_sinks() {
    Machine m(std::string(registers) + R"(
        IDX    i, =#0x800, 0
        MAC    [i+0], 0, A_, =1.0
        MAC    [i+1], 0, =1.0, =1.0
)");
    m.set("A_", q(0.5)).start();
    const csp::PassReport first = m.run();
    check_equal(m.processor.sink(0), q(0.5),
                "a sink written in a pass is published at its end");
    check(first.stale_sinks.empty(), "every owned sink written: none stale");
}

void test_firmware_sinks() {
    Machine m(std::string(registers) + "NOP\n");
    m.start();
    m.processor.write(csp::sink_base + 7, q(0.25));
    m.processor.write(csp::sink_base + csp::sink_count,
                      q(1.0)); // beyond the sinks
    m.run();
    check_equal(m.processor.sink(7), 0,
                "a queued sink write waits for the swap");
    m.processor.swap();
    m.run();
    check_equal(m.processor.sink(7), q(0.25),
                "the window applies it, and the pass publishes it");
    m.run();
    check_equal(m.processor.sink(7), q(0.25),
                "it is in both pages, so the next flip keeps it");
    m.run();
    check_equal(m.processor.sink(7), q(0.25), "and the one after");
}

// ---- the assembler ----------------------------------------------------------------

void test_assembler() {
    check(has_diagnostic(csp::assemble("FOO r1, r2\n"), true,
                         "unknown instruction"),
          "unknown instruction");
    check(has_diagnostic(csp::assemble("MAC r1100, 0, r1, r2\n"), true,
                         "reaches 0–1023"),
          "direct operands reach 0–1023");
    check(has_diagnostic(csp::assemble("CMP.d r2, r4, r6\n"), true,
                         "no dword form"),
          ".d on an instruction without one");
    check(has_diagnostic(csp::assemble("MAC r1, r2, r3, r4\n"), true,
                         "must be 0 or the R"),
          "an A operand that is not 0 or R");
    check(has_diagnostic(csp::assemble("MAC r1, 0, =1.0, =2.0\n"), true,
                         "one immediate a word"),
          "two different immediates in one word");
    check(csp::assemble("MAC r1, 0, =1.0, =1.0\n").ok,
          "the same immediate twice is one immediate");
    check(has_diagnostic(
                  csp::assemble(
                          "LOOP.i 2, =#2, =#1\nLOOP.i 1, =#2, =#1\nNOP\n"),
                  true, "different index"),
          "nested loops on the same index register");
    check(has_diagnostic(
                  csp::assemble(
                          "LOOP.i 3, =#2, =#1\nLOOP.j 3, =#2, =#1\nNOP\nNOP\nNOP\n"),
                  true, "past its outer loop"),
          "an inner loop past its outer loop's end");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#2, =#1\n"), true,
                         "past the program's end"),
          "a loop past the end of the program");
    check(has_diagnostic(csp::assemble(".dword W, 0x061\n"), true, "even"),
          "a dword at an odd address");
    check(has_diagnostic(csp::assemble("MAC r64, 0, r1, r2\n"), true, "input"),
          "no result into an input register");

    const csp::Program block = csp::assemble(R"(
        .block VOICE
        .field LEVEL, 2
        .field STAGE, 1
        .end
)");
    check_equal(block.symbols.at("STAGE"), 2, ".field offsets add up");
    check_equal(block.symbols.at("VOICE_SIZE"), 3,
                ".end defines the block's size");
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
    check_equal(m.get("A_"), q(3.0),
                "LOOP closed by a label runs its whole body");
    check_equal(m.get("B_"), q(3.0), "both body instructions, three times");
    check_equal(m.get("D_"), q(3.0), "and the labelled instruction runs");
    check(has_diagnostic(csp::assemble("LOOP.i nowhere, =#2, =#1\nNOP\n"), true,
                         "unknown label"),
          "a LOOP naming an unknown label");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#1024, =#1\nNOP\n"), true,
                         "0–1023"),
          "a count over ten bits");
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
    b.idx(IndexRegister::i, Source::imm(0x200),
          Source::reg(Operand::direct(0)));
    const size_t loop = b.open_loop(IndexRegister::i, 4, 16);
    b.add3(level, ASource::result, Source::reg(rate), Source::reg(target));
    b.close_loop(loop);
    const csp::ProgramBuilder::Built built = b.build();
    check(built.ok && built.issues.empty(),
          "a well-formed built program has no issues");

    const csp::Program text = csp::assemble(R"(
        .equ    VOICES, 0x200
        .reg RATE, 0x061
        .reg TARGET, 0x062
        IDX    i, =#VOICES, 0
        LOOP.i end, =#4, =#16
        ADD3 [i+0], [i+0], RATE, TARGET
end:
)");
    check(text.ok && text.image.rows == built.image.rows
                  && text.image.rom == built.image.rom
                  && text.image.length == built.image.length,
          "the builder and the assembler emit the same image");

    csp::ProgramBuilder bad;
    bad.mac(Operand::indexed(IndexRegister::j, 0), ASource::zero,
            Source::reg(Operand::direct(1100)),
            Source::reg(Operand::direct(1)));
    (void) bad.open_loop(IndexRegister::i, 1, 1);
    bool reach = false, unclosed = false;
    for (const csp::BuildIssue &found : bad.build().issues) {
        reach = reach
                || found.message.find("reaches 0–1023") != std::string::npos;
        unclosed = unclosed
                   || found.message.find("never closed") != std::string::npos;
    }
    check(reach && unclosed,
          "the builder reports reach, and a loop never closed");
}

// An IDX that says which addresses its index may hold: a pointer. Each
// instruction's row is the cycle it issues in, the program being straight-line.
void test_builder_index_targets() {
    using csp::ASource;
    using csp::IndexRegister;
    using csp::Operand;
    using csp::Source;
    const Operand pointer = Operand::direct(0x060);
    const Operand value   = Operand::direct(0x071);
    const Source zero     = Source::reg(Operand::direct(0));
    const std::array<int, 2> blocks{0x200, 0x210};
    auto through = [](int offset) {
        return Operand::indexed(IndexRegister::j, offset);
    };
    auto copy = [&](csp::ProgramBuilder &b, Operand to, Operand from) {
        return b.add3(to, ASource::zero, Source::reg(from), zero);
    };
    // the program, with the list or without it
    struct Rows {
        size_t behind_another_word, behind_a_named_word, another_offset,
                direct_behind_the_index, direct_elsewhere;
    };
    auto program = [&](csp::ProgramBuilder &b, bool with_targets) {
        if (with_targets) {
            b.idx(IndexRegister::j, Source::reg(pointer), zero,
                  b.targets(blocks));
        } else {
            b.idx(IndexRegister::j, Source::reg(pointer), zero);
        }
        Rows rows{};
        copy(b, Operand::direct(0x070), value);
        rows.behind_another_word = copy(b, Operand::direct(0x072), through(1));
        copy(b, Operand::direct(0x211), value);
        rows.behind_a_named_word = copy(b, Operand::direct(0x073), through(1));
        rows.another_offset      = copy(b, Operand::direct(0x074), through(2));
        copy(b, through(3), value);
        rows.direct_behind_the_index =
                copy(b, Operand::direct(0x075), Operand::direct(0x213));
        rows.direct_elsewhere =
                copy(b, Operand::direct(0x076), Operand::direct(0x214));
        return rows;
    };
    csp::ProgramBuilder with, without;
    const Rows rows = program(with, true);
    program(without, false);
    const csp::ProgramBuilder::Built built = with.build();
    const csp::ProgramBuilder::Built plain = without.build();
    check(built.ok && plain.ok, "the pointer programs build");
    // the write to another word issues in the IDX's wait, so the first read
    // through j stands in the row j lands in
    const int after_idx = csp::index_latency - 1;
    check_equal(
            static_cast<int64_t>(built.position[rows.behind_another_word]),
            after_idx + 1,
            "a read through a pointer does not wait for a write to a word outside its list");
    check_equal(static_cast<int64_t>(built.position[rows.behind_a_named_word]),
                after_idx + 2 + csp::result_latency,
                "it waits for a write to a word of its list");
    check_equal(static_cast<int64_t>(built.position[rows.another_offset]),
                after_idx + 3 + csp::result_latency,
                "another offset of the same blocks is another word");
    check_equal(
            static_cast<int64_t>(built.position[rows.direct_behind_the_index]),
            after_idx + 4 + 2 * csp::result_latency,
            "a write through a pointer is a write to every word it may name");
    check_equal(static_cast<int64_t>(built.position[rows.direct_elsewhere]),
                after_idx + 5 + 2 * csp::result_latency,
                "and to no other word");
    check_equal(
            static_cast<int64_t>(plain.position[rows.behind_another_word]),
            1 + csp::result_latency,
            "without a list, a read through an index waits for every earlier write");
    check(built.cycles < plain.cycles,
          "the list makes the pass shorter: " + std::to_string(built.cycles)
                  + " cycles against " + std::to_string(plain.cycles));

    // on the model, the pointer at each block of its list
    for (const int block : blocks) {
        csp::Processor cpu;
        cpu.write(0x060, block);
        cpu.write(0x071, q(0.75));
        cpu.write(block + 1, q(0.25));
        cpu.write(block + 2, q(-0.5));
        cpu.swap();
        cpu.pass();
        check(cpu.load(built.image), "the pointer program loads");
        cpu.release();
        const csp::PassReport report = cpu.pass();
        for (const std::string &error : report.errors) {
            std::printf("  model: %s\n", error.c_str());
        }
        const std::string where = ", the pointer at " + std::to_string(block);
        check(report.errors.empty(), "the model reads nothing early" + where);
        check_equal(report.cycles, built.cycles,
                    "the model counts the builder's cycles" + where);
        // only the second block's word 1 is overwritten before the second read
        check_equal(cpu.read(0x072), q(0.25),
                    "the first read is the word as it was" + where);
        check_equal(cpu.read(0x073), block == 0x210 ? q(0.75) : q(0.25),
                    "the second read is behind the write" + where);
        check_equal(cpu.read(0x074), q(-0.5), "the third read" + where);
        check_equal(cpu.read(block + 3), q(0.75),
                    "the write through the pointer" + where);
    }

    // the list is a promise: a pointer outside it reads a word early, and the model says so
    csp::ProgramBuilder broken;
    broken.idx(IndexRegister::j, Source::reg(pointer), zero,
               broken.targets(blocks));
    copy(broken, Operand::direct(0x221), value);
    copy(broken, Operand::direct(0x072), through(1));
    const csp::ProgramBuilder::Built unkept = broken.build();
    csp::Processor cpu;
    cpu.write(0x060, 0x220);
    cpu.swap();
    cpu.pass();
    check(unkept.ok && cpu.load(unkept.image),
          "the program with the unkept promise builds and loads");
    cpu.release();
    check(!cpu.pass().errors.empty(),
          "the model reports the early read of a pointer outside its list");
}

// ---- the programs ---------------------------------------------------------------

const char *envelope_program = R"(
        .block VOICE
        .field LEVEL, 2                     ; dword
        .field STAGE, 1                     ; 0 attack, 4 decay, 8 release: the firmware's to start and end
        .field SPARE_VOICE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .field U, 1                         ; scratch
        .end
        .block SEGMENT                      ; a row of the envelope table
        .field TARGET, 2                    ; dword
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ    VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060             ; the table's address, raw

        IDX     i, =#VOICES, 0              ; i → voice 0
        LOOP.vi done, =#2, =#16             ; every voice
        IDX     j, ENV_TABLE, [i+STAGE]     ;   j → this segment's row
        MAX     [i+U], [i+STAGE], =#4       ;   attack → decay, if…
        CMP     ZERO, [i+LEVEL], FULL       ;   …full scale is reached
        SEL     [i+STAGE], [i+U], [i+STAGE] ;   (SEL reads the CMP's flags)
        CMP     [i+U], [j+TARGET], [i+LEVEL]   ;   U ← target − level (the distance)
        MAC.d   [i+LEVEL], [i+U], [j+RATE]     ;   level ← level + U × rate
done:
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
    m.processor.write(voice + 2, 0);      // voice 0: struck, in attack
    m.processor.write(voice + 4, q(1.0)); //          velocity 1
    m.processor.write(voice + 16 + 2, 8); // voice 1: idle, in release
    m.start();

    int passes_to_decay = 0;
    double previous     = 0;
    bool rising         = true;
    bool clean          = true;
    for (int pass = 1; pass <= 200 && m.processor.read(voice + 2) == 0;
         ++pass) {
        clean              = clean && m.run().errors.empty();
        const double level = m.processor.read(voice) / double(csp::word_one);
        rising             = rising && level >= previous;
        previous           = level;
        passes_to_decay    = pass;
    }
    check(clean, "the envelope program runs without early reads");
    check(rising, "attack rises every pass");
    check_equal(m.processor.read(voice + 2), 4, "the attack ends in decay");
    check(passes_to_decay > 5 && passes_to_decay < 30,
          "the attack takes a plausible number of passes");
    check(previous >= 1.0, "the level reached full scale");
    check_equal(m.processor.read(0x600 + 16 + 2), 8,
                "voice 1, never struck, sits in release");
    check_equal(m.processor.read(0x600 + 16), 0, "at zero");

    for (int pass = 0; pass < 400; ++pass) {
        m.processor.pass();
    }
    const double sustained = m.processor.read(voice) / double(csp::word_one);
    check(std::abs(sustained - 0.5) < 0.001,
          "decay settles at the sustain level");

    // stolen while held (#267): the firmware writes attack again, and the
    // level climbs on from where it is, not from zero
    m.processor.write(voice + 2, 0);
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 0,
                "a voice struck again is in attack");
    const double retriggered = m.processor.read(voice) / double(csp::word_one);
    check(retriggered > sustained && retriggered < 1.0,
          "the retrigger climbs on from the sustain level: "
                  + std::to_string(retriggered));
    for (int pass = 0; pass < 100 && m.processor.read(voice + 2) == 0; ++pass) {
        m.processor.pass();
    }
    check_equal(m.processor.read(voice + 2), 4,
                "and ends in decay at full scale");

    m.processor.write(voice + 2, 8); // let go: the firmware writes release
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 8,
                "let go: the program leaves release alone");
    for (int pass = 0; pass < 400; ++pass) {
        m.processor.pass();
    }
    check(m.processor.read(voice) < q(0.001), "release falls toward zero");
}

void test_lfo() {
    check(has_diagnostic(csp::assemble("SEL r1, =-1.0, =1.0\n"), true,
                         "one immediate"),
          "SEL with two different immediates does not assemble: the square's levels come from registers");
    Machine lfo(R"(
        .dword  PHASE, 0x060
        .dword  RATE, 0x062
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

        MACW.d  PHASE, ONE, RATE            ; advance and wrap
        MAC     SAW, 0, PHASE, DEPTH_8      ; sawtooth, ±depth
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, LOW, HIGH           ; square, ±depth
        ABS     T, PHASE                    ; 0 … 8
        MAC     TRI, 0, T, DEPTH_4          ; 0 … 2 × depth
        ADD3    TRI, TRI, NEG_DEPTH, ZERO   ; triangle, ±depth
)");
    lfo.set("HIGH", q(1.0))
            .set("LOW", q(-1.0))
            .set_wide("RATE", q_wide(16.0 / 8))
            .start(); // 8 passes per cycle
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
        check(lfo.get("SQUARE") == (lfo.get("PHASE") < 0 ? q(1.0) : q(-1.0)),
              "square follows the phase's sign");
    }
    check_equal(wraps, 2, "the saw wraps once per 8 passes");
    check(lowest == q(-1.0) && highest >= q(0.75), "the triangle spans ±depth");
}

// A segment's time constant as a dword rate for a pass: the fraction of the
// distance the exponential covers in a pass, a 24 000th of a second (#268).
void test_envelope_rates() {
    const float time_constants[] = {0.0002f, 0.001f, 0.01f, 0.1f,
                                    1.0f,    10.0f,  30.0f};
    int64_t previous             = int64_t{1} << 32;
    for (const float time_constant : time_constants) {
        const double want =
                1.0
                - std::exp(-1.0
                           / (static_cast<double>(time_constant) * 24000.0));
        const int64_t rate = csp::envelope_rate(time_constant);
        const double got   = static_cast<double>(rate)
                           / static_cast<double>(int64_t{1} << 32);
        const std::string name =
                "time constant " + std::to_string(time_constant);
        // within a unit of the rate's last place, 2^-32
        check(std::fabs(got - want)
                      <= 1.0 / static_cast<double>(int64_t{1} << 32),
              name + ": fraction " + std::to_string(got) + ", want "
                      + std::to_string(want));
        check(rate > 0 && rate < previous,
              name + ": a slower segment is a smaller step, and still a step");
        previous = rate;
    }
}

// An LFO's cycles a second as a dword step: the phase's 36 bits are a cycle,
// stepped once a pass.
void test_lfo_rate() {
    const double passes_a_second =
            96000.0 / csp::samples_per_pass; // 24 kHz (#268)
    for (const float hertz : {0.0029f, 1.0f, 2.861f, 187.0f}) {
        const double exact = static_cast<double>(hertz) / passes_a_second
                             * static_cast<double>(int64_t{1} << 36);
        check(std::fabs(static_cast<double>(csp::lfo_rate(hertz)) - exact)
                      <= 0.5,
              "lfo_rate: " + std::to_string(hertz)
                      + " Hz, to the nearest step");
    }
    check_equal(csp::lfo_rate(0.0f), 0, "lfo_rate: a stopped LFO");
    check(csp::lfo_rate(187.0f) < (int64_t{1} << 35),
          "lfo_rate: the fastest LFO is below half a cycle a pass");
}

// ---- the boot self-test ------------------------------------------------------

// The self-test's program (app/main/csp/selftest.cpp): what the firmware
// checks at boot, on the model.
void test_selftest_program() {
    namespace st     = csp::selftest;
    const auto built = std::make_unique<csp::ProgramBuilder::Built>();
    st::build(*built);
    check(built->ok && built->issues.empty(),
          "the self-test builds without issues");
    csp::Processor processor;
    check(processor.load(built->image), "the self-test loads while held");
    processor.release();
    // the pass counter's register holds 0 in the first pass after reset (nothing wrote it yet)
    // and the pass's number from the second on; the program sees that value
    int odd_passes = 0;
    for (int pass = 1; pass <= 4; ++pass) {
        const csp::PassReport report = processor.pass();
        for (const std::string &error : report.errors) {
            std::printf("  model: %s\n", error.c_str());
        }
        check(report.errors.empty(), "the self-test runs without early reads");
        const int seen = pass == 1 ? 0 : pass;
        const int bit  = seen & 1;
        odd_passes += bit;
        check_equal(processor.read(st::res_pass_bit), bit,
                    "res_pass_bit follows the pass counter");
        check_equal(processor.read(st::res_half), bit * 8,
                    "res_half is the bit × 8");
        check_equal(processor.read(st::res_chain), bit ? 0x808 : 0x4000,
                    "res_chain reads the table through IDX");
        check_equal(processor.read(st::res_abs), q(4.0), "ABS of −4.0");
        check_equal(processor.read(st::res_mac), q(0.5),
                    "MAC after it, 4.0 × 0.125");
        check_equal(processor.read(st::res_add3), q(-3.5),
                    "ADD3 after that, 0.5 − 4.0");
        check_equal(processor.read(st::res_sel), q(0.125), "SEL after a CMP");
        check_equal(processor.read(st::res_max), q(4.0), "MAX of 4.0 and −4.0");
        check_equal(processor.read(st::res_min), q(-4.0),
                    "MIN of 4.0 and −4.0");
        check_equal(processor.read(st::count_total), pass,
                    "count_total counts the passes");
        check_equal(processor.read(st::count_passes), pass,
                    "count_passes, which wraps, counts them too");
        check_equal(processor.read(st::pass_via_logic), seen,
                    "the logic unit's copy of the pass counter");
        check_equal(processor.read(st::pass_via_dsp), seen,
                    "the multiply-add's copy");
        check_equal(processor.read(st::pass_via_logic_a), seen,
                    "the logic unit's second copy");
        check_equal(processor.read(st::pass_via_logic_b), seen,
                    "and its third");
    }
    check_equal(processor.read(st::count_odd), odd_passes,
                "count_odd counts the odd passes");
    check_equal(processor.read(st::count_half_odd), odd_passes,
                "count_half_odd agrees");
    check_equal(processor.read(st::count_chain_odd), odd_passes,
                "count_chain_odd agrees");
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
    test_builder_index_targets();
    test_envelope();
    test_lfo();
    test_envelope_rates();
    test_lfo_rate();
    test_selftest_program();
    std::printf("csp: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
