// csp_test.cpp — host tests for the CSP reference model and assembler
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every instruction at its edges (formats, truncation, saturation, wrap,
// flags), the rules a program can see (IDX delay slots, loops, SKIP, the
// write queue and swap, reset, pass limits, sink pages), the assembler's
// checks, and the programs in docs/csp_manual.md section 8.
//
//   make csp-test

#include <cmath>
#include <cstdio>
#include <string>
#include <string_view>
#include <vector>

#include "../assembler.hpp"
#include "../processor.hpp"
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

// A program assembled and loaded on a fresh processor, with its constants
// and any register values set while the CSP is held.
class Machine {
public:
    explicit Machine(std::string_view source) : program(csp::assemble(source)) {
        for (const csp::Diagnostic &d : program.diagnostics) {
            if (d.error) {
                std::printf("  assembly error, line %d: %s\n", d.line,
                            d.message.c_str());
            }
        }
        check(program.ok(), "program assembles");
        for (const csp::ConstantWrite &constant : program.constants) {
            processor.write(constant.address, constant.raw);
        }
    }

    Machine &set(const std::string &name, int32_t raw) {
        processor.write(address(name), raw);
        return *this;
    }

    Machine &set_wide(const std::string &name, int64_t raw) {
        processor.write_wide(address(name), raw);
        return *this;
    }

    // Apply the constants and settings while held, load, release.
    Machine &start() {
        processor.swap();
        processor.pass();
        check(processor.load(program.words), "program loads while held");
        processor.release();
        return *this;
    }

    csp::PassReport run() {
        return processor.pass();
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

// ---- encoding ---------------------------------------------------------------

void test_encoding() {
    const csp::Instruction ins{
            csp::Opcode::interp, csp::ASelect::wide,
            csp::Operand::indexed(csp::IndexRegister::i, 0).encode(),
            csp::Operand::indexed(csp::IndexRegister::j, 2).encode(),
            csp::Operand::direct(0x1FF).encode()};
    const uint64_t word = ins.encode();
    check(word < (uint64_t{1} << 36), "an instruction is 36 bits");
    check(csp::Instruction::decode(word) == ins,
          "encode and decode round-trip");
    check_equal(word >> 32, 3, "INTERP's opcode is 3");
    check(csp::Instruction{}.encode() == 0, "an all-zero word is NOP");
    check(csp::Operand::decode(0x305)
                  == csp::Operand::indexed(csp::IndexRegister::j, 5),
          "operand 11 00000101 is j+5");
    check(csp::Operand::decode(0x0FF) == csp::Operand::direct(0xFF),
          "operand 0 011111111 is direct 255");
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
    check_equal(tiny.get("C_"), -1,
                "MAC truncates −2⁻²⁸ toward minus infinity");
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
    check_equal(m.get("W_"), q(-7.75),
                "a wide register's upper word reads as Q4.14");
}

void test_interp() {
    Machine m(std::string(registers) + R"(
        INTERP   A_, A_, B_, C_
        INTERP.w W_, B_, V_
)");
    m.set("B_", q(0.5)).set("C_", q(1.0)).set_wide("V_", q_wide(1.0)).start();
    m.run();
    check_equal(m.get("A_"), q(0.5), "INTERP moves halfway");
    check_equal(m.get_wide("W_"), q_wide(0.5), "INTERP.w moves halfway");
    m.run();
    check_equal(m.get("A_"), q(0.75), "INTERP again: three quarters");
    check_equal(m.get_wide("W_"), q_wide(0.75),
                "INTERP.w again: three quarters");
}

void test_acc() {
    Machine m(std::string(registers) + R"(
        ACC  0, B_, C_
        ACC  acc, B_, C_
        MAC  A_, acc, B_, C_
        MAC  D_, 0, B_, C_
        MAC  D_, D_, B_, C_
        MAC  D_, D_, B_, C_
)");
    // 2⁻⁷ × 2⁻⁸ = 2⁻¹⁵: half a raw step each. Summed in the accumulator,
    // three make 1.5 steps, truncated once to 1; rounded every time, 0.
    m.set("B_", q(1.0 / 128)).set("C_", q(1.0 / 256)).start().run();
    check_equal(m.get("A_"), 1,
                "ACC chain rounds once: three half steps make 1");
    check_equal(m.get("D_"), 0, "separate MACs truncate each half step away");
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

void test_skip() {
    Machine m(std::string(registers) + R"(
        CMP   ZERO, B_, C_          ; 1 − 2: negative
        SKIP  neg, 2
        MAC   A_, 0, =1.0, =1.0
        MAC   A_, 0, =2.0, =1.0
        MAC   D_, 0, =3.0, =1.0
)");
    m.set("B_", q(1.0)).set("C_", q(2.0)).start();
    const csp::PassReport report = m.run();
    check_equal(m.get("A_"), 0, "SKIP neg skips the next two");
    check_equal(m.get("D_"), q(3.0), "the instruction after them runs");
    check_equal(report.cycles, 5,
                "skipped instructions still take their cycles");
}

void test_index_delay() {
    Machine m(std::string(registers) + R"(
        .equ BASE, 0x100
        IDX   i, =#BASE, 0
        MAC   [i+1], 0, =1.0, =1.0   ; slot 1: old i (0) → register 1
        MAC   [i+2], 0, =1.0, =1.0   ; slot 2
        MAC   [i+3], 0, =1.0, =1.0   ; slot 3
        MAC   [i+4], 0, =1.0, =1.0   ; fourth: new i → 0x104
)");
    check(has_diagnostic(m.program, false, "delay slot"),
          "the assembler warns about delay slots");
    m.start().run();
    check_equal(m.processor.read(0x104), q(1.0),
                "the fourth instruction after IDX sees the new i");
    check_equal(m.processor.read(0x101), 0, "the first three do not");
    check_equal(m.processor.read(1), q(1.0), "they still used the old i (0)");
}

void test_loops() {
    Machine m(std::string(registers) + R"(
        .equ BASE, 0x200
        IDX    i, =#BASE, 0
        NOP
        NOP
        NOP
        LOOP.i 1, =#4, =#16           ; 4 blocks of 16
        ADD3   [i+0], [i+0], =1.0, ZERO
        IDX    j, =#0x300, 0
        NOP
        NOP
        NOP
        LOOP.i 3, =#2, =#1            ; outer: 2 passes over i
        NOP
        LOOP.j 1, =#3, =#1            ;   inner: 3 passes over j
        ADD3   [j+0], [j+0], =1.0, ZERO
        LOOP.i 1, ZERO, =#1           ; count 0: the body is skipped
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

void test_reset() {
    Machine m(std::string(registers) + "ADD3 A_, A_, =1.0, ZERO\n");
    m.start();
    m.run();
    m.processor.hold();
    m.run();
    check_equal(m.get("A_"), q(1.0), "a held CSP runs no program");
    check(m.processor.load(m.program.words), "a program loads while held");
    m.processor.release();
    m.run();
    check_equal(m.get("A_"), q(2.0), "reset clears no registers");
    check(!m.processor.load(m.program.words),
          "a program does not load while running");
}

void test_pass_limit() {
    std::string source;
    for (int n = 0; n < csp::max_program_length + 1; ++n) {
        source += "NOP\n";
    }
    check(has_diagnostic(csp::assemble(source), true, "a pass holds"),
          "the assembler rejects a program over 1472 instructions");

    Machine m(std::string(registers) + "LOOP.i 1, =#2000, ZERO\nNOP\n");
    m.start();
    const csp::PassReport report = m.run();
    check(!report.errors.empty(),
          "the model stops a pass that runs over 1472 cycles");
}

void test_sinks() {
    Machine m(std::string(registers) + R"(
        IDX    i, =#0x800, 0
        NOP
        NOP
        NOP
        MAC    [i+0], 0, A_, =1.0
        CMP    ZERO, B_, ZERO
        SKIP   neg, 1
        MAC    [i+1], 0, =1.0, =1.0
)");
    m.set("A_", q(0.5)).start();
    const csp::PassReport first = m.run();
    check_equal(m.processor.sink(0), q(0.5),
                "a sink written in a pass is published at its end");
    check(first.stale_sinks.empty(), "every owned sink written: none stale");
    m.processor.write(m.address("B_"), q(-1.0));
    m.processor.swap();
    m.run(); // the window applies B_ = −1 at its end
    const csp::PassReport third = m.run();
    check(third.stale_sinks.size() == 1 && third.stale_sinks[0] == 1,
          "a sink word skipped in a pass is reported stale");
}

// ---- the assembler ----------------------------------------------------------------

void test_assembler() {
    check(has_diagnostic(csp::assemble("FOO r1, r2\n"), true,
                         "unknown instruction"),
          "unknown instruction");
    check(has_diagnostic(csp::assemble("MAC r600, 0, r1, r2\n"), true,
                         "beyond direct reach"),
          "direct operands reach 0–511");
    check(has_diagnostic(csp::assemble("CMP.w r2, r4, r6\n"), true,
                         "no wide form"),
          ".w on an instruction without a wide form");
    check(has_diagnostic(csp::assemble("MAC r1, r2, r3, r4\n"), true,
                         "must be 0, acc or the R"),
          "an A operand that is not 0, acc or R");
    check(has_diagnostic(
                  csp::assemble(
                          "LOOP.i 2, =#2, =#1\nLOOP.i 1, =#2, =#1\nNOP\n"),
                  true, "same index register"),
          "nested loops on the same index register");
    check(has_diagnostic(
                  csp::assemble(
                          "LOOP.i 3, =#2, =#1\nLOOP.j 3, =#2, =#1\nNOP\nNOP\nNOP\n"),
                  true, "past its outer loop"),
          "an inner loop past its outer loop's end");
    check(has_diagnostic(csp::assemble("LOOP.i 1, =#2, =#1\n"), true,
                         "past the end"),
          "a loop past the end of the program");
    check(has_diagnostic(
                  csp::assemble(
                          "SKIP always, 2\nNOP\nLOOP.i 1, =#2, =#1\nNOP\n"),
                  true, "crosses a loop"),
          "SKIP over a LOOP");
    check(has_diagnostic(csp::assemble(".wide W, 0x061\n"), true, "even"),
          "a wide register at an odd address");

    const csp::Program pool = csp::assemble(R"(
        .const ONE, 1.0
        MAC r96, 0, =1.0, ONE
        MAC r97, 0, =#16384, =0.5
)");
    check(pool.ok(), "constants assemble");
    check_equal(
            static_cast<int64_t>(pool.constants.size()), 2,
            "equal constants share a register (1.0 and #16384), 0.5 gets its own");

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
    // A LOOP and a SKIP closed by labels further on, as firmware authors
    // would write them: nobody counts body lengths by hand.
    Machine m(std::string(registers) + R"(
        LOOP.i done, =#3, ZERO
        ADD3   A_, A_, =1.0, ZERO
        ADD3   B_, B_, =1.0, ZERO
done:   CMP    ZERO, ZERO, =1.0         ; negative
        SKIP   neg, after
        MAC    C_, 0, =1.0, =1.0
        MAC    C_, 0, =2.0, =1.0
after:  MAC    D_, 0, =3.0, =1.0
)");
    m.start().run();
    check_equal(m.get("A_"), q(3.0),
                "LOOP closed by a label runs its whole body");
    check_equal(m.get("B_"), q(3.0), "both body instructions, three times");
    check_equal(m.get("C_"), 0, "SKIP closed by a label skips up to it");
    check_equal(m.get("D_"), q(3.0), "and the labelled instruction runs");
    check(has_diagnostic(csp::assemble("LOOP.i nowhere, =#2, =#1\nNOP\n"), true,
                         "unknown label"),
          "a LOOP naming an unknown label");

    // The count is unsigned: −1 is a huge count, which the pass limit stops.
    Machine negative(std::string(registers)
                     + "LOOP.i 1, =-0.00006103515625, ZERO\nNOP\n");
    negative.start();
    check(!negative.run().errors.empty(),
          "a negative raw count runs into the pass limit");
}

// The firmware builds programs with ProgramBuilder directly: the same
// program built in C++ and assembled from text gives the same words.
void test_builder() {
    using csp::ASelect;
    using csp::IndexRegister;
    using csp::Operand;
    csp::ProgramBuilder b;
    const Operand level  = Operand::indexed(IndexRegister::i, 0);
    const Operand rate   = Operand::direct(0x061);
    const Operand target = Operand::direct(0x062);
    b.idx(IndexRegister::i, Operand::direct(0x060), Operand::direct(0));
    b.nop();
    b.nop();
    b.nop();
    const size_t loop = b.open_loop(IndexRegister::i, Operand::direct(0x063),
                                    Operand::direct(0x064));
    b.interp(level, ASelect::result, rate, target);
    b.close_loop(loop);
    check(b.check().empty(), "a well-formed built program has no issues");

    const csp::Program text = csp::assemble(R"(
        .reg BASE, 0x060
        .reg RATE, 0x061
        .reg TARGET, 0x062
        .reg COUNT, 0x063
        .reg STRIDE, 0x064
        IDX    i, BASE, ZERO
        NOP
        NOP
        NOP
        LOOP.i end, COUNT, STRIDE
        INTERP [i+0], [i+0], RATE, TARGET
end:
)");
    check(text.ok() && text.words == b.words(),
          "the builder and the assembler emit the same words");

    csp::ProgramBuilder bad;
    bad.idx(IndexRegister::j, Operand::direct(1), Operand::direct(2));
    bad.mac(Operand::indexed(IndexRegister::j, 0), ASelect::zero,
            Operand::direct(600), Operand::direct(1));
    const size_t open = bad.open_loop(IndexRegister::i, Operand::direct(1),
                                      Operand::direct(1));
    (void) open;
    bool delay = false, reach = false, unclosed = false;
    for (const csp::BuildIssue &found : bad.check()) {
        delay = delay || found.message.find("delay slot") != std::string::npos;
        reach = reach
                || found.message.find("direct reach") != std::string::npos;
        unclosed = unclosed
                   || found.message.find("never closed") != std::string::npos;
    }
    check(delay && reach && unclosed,
          "the builder reports delay slots, reach, and a loop never closed");
}

// ---- the manual's programs (docs/csp_manual.md section 8) ---------------------------

const char *envelope_program = R"(
        .block VOICE
        .field LEVEL, 2                     ; wide
        .field STAGE, 1                     ; 0 attack, 4 decay, 8 release
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .end
        .block SEGMENT                      ; a row of the envelope table
        .field TARGET, 2                    ; wide
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ   VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060             ; the table's address, raw
        .reg   U, 0x061

        IDX     i, =#VOICES, 0              ; i → voice 0
        NOP
        NOP
        NOP
        LOOP.i  9, =#2, =#16                ; each voice
        IDX     j, ENV_TABLE, [i+STAGE]     ;   j → this segment's row
        MAX     U, [i+STAGE], =#4           ;   attack → decay, if…
        CMP     ZERO, [i+LEVEL], FULL       ;   …full scale is reached
        SEL     [i+STAGE], U, [i+STAGE]     ;   (SEL reads the CMP's flags)
        ANDXOR  U, 0, [i+STAGE], =#4        ;   release → attack: 0/4/8 → 0/4/0
        CMP     ZERO, [i+GATE], FULL        ;   gate held?
        SEL     [i+STAGE], U, =#8           ;     else release
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
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
    for (int pass = 1; pass <= 200 && m.processor.read(voice + 2) == 0;
         ++pass) {
        m.run();
        const double level = m.processor.read(voice) / double(csp::word_one);
        rising             = rising && level >= previous;
        previous           = level;
        passes_to_decay    = pass;
    }
    check(rising, "attack rises every pass");
    check_equal(m.processor.read(voice + 2), 4, "the attack ends in decay");
    check(passes_to_decay > 5 && passes_to_decay < 30,
          "the attack takes a plausible number of passes");
    check(previous >= 1.0, "the level reached full scale");
    check_equal(m.processor.read(0x600 + 16 + 2), 8,
                "voice 1, gate off, sits in release");
    check_equal(m.processor.read(0x600 + 16), 0, "at zero");

    for (int pass = 0; pass < 400; ++pass) {
        m.run();
    }
    const double sustained = m.processor.read(voice) / double(csp::word_one);
    check(std::abs(sustained - 0.5) < 0.001,
          "decay settles at the sustain level");
    check_equal(m.processor.read(voice + 5), m.processor.read(voice),
                "the output is level × velocity 1.0");

    m.processor.write(voice + 3, 0); // gate off
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 8, "gate off: release");
    for (int pass = 0; pass < 400; ++pass) {
        m.run();
    }
    check(m.processor.read(voice) < q(0.001), "release falls toward zero");

    m.processor.write(voice + 3, q(1.0)); // gate on again
    m.processor.swap();
    m.run();
    m.run();
    check_equal(m.processor.read(voice + 2), 0,
                "a new gate restarts the attack");
}

void test_lfo() {
    Machine m(R"(
        .wide  PHASE, 0x060
        .wide  RATE, 0x062
        .reg   SAW, 0x064
        .reg   SQUARE, 0x065
        .reg   T, 0x066
        .reg   TRI, 0x067
        .const ONE, 1.0
        .const DEPTH, 1.0
        .const NEG_DEPTH, -1.0
        .const DEPTH_8, 0.125
        .const DEPTH_4, 0.25

        MACW.w  PHASE, ONE, RATE            ; advance and wrap
        MAC     SAW, 0, PHASE, DEPTH_8      ; sawtooth, ±depth
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, DEPTH, NEG_DEPTH    ; square, ±depth
        ABS     T, PHASE                    ; 0 … 8
        MAC     TRI, 0, T, DEPTH_4          ; 0 … 2 × depth
        ADD3    TRI, TRI, NEG_DEPTH, ZERO   ; triangle, ±depth
)");
    m.set_wide("RATE", q_wide(16.0 / 8)).start(); // 8 passes per cycle
    int wraps            = 0;
    int32_t previous_saw = 0;
    int32_t lowest       = 0;
    int32_t highest      = 0;
    for (int pass = 0; pass < 16; ++pass) {
        m.run();
        const int32_t saw = m.get("SAW");
        wraps += saw < previous_saw;
        previous_saw = saw;
        lowest       = std::min(lowest, m.get("TRI"));
        highest      = std::max(highest, m.get("TRI"));
        check(m.get("SQUARE") == (m.get("PHASE") < 0 ? q(-1.0) : q(1.0)),
              "square follows the phase's sign");
    }
    check_equal(wraps, 2, "the saw wraps once per 8 passes");
    check(lowest == q(-1.0) && highest >= q(0.75), "the triangle spans ±depth");
}

} // namespace

int main() {
    test_encoding();
    test_mac();
    test_macw_and_wide();
    test_interp();
    test_acc();
    test_add3_sel_cmp_min_max();
    test_andxor_shift_abs_nop();
    test_skip();
    test_index_delay();
    test_loops();
    test_queue_and_swap();
    test_reset();
    test_pass_limit();
    test_sinks();
    test_assembler();
    test_labels_and_count();
    test_builder();
    test_envelope();
    test_lfo();
    std::printf("csp: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}
