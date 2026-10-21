// csp_cosim.cpp — the CSP's RTL against tools/csp's reference model
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Runs the same programs and firmware writes on the RTL (Verilated
// tb_csp_cosim.sv) and on the reference model, and after every pass
// compares everything a program can leave behind: all 2048 registers, the
// published sink page, i, j, the accumulator, the flags, the cycles the
// pass took, and that DMEM's row rule held at every edge. Programs come from
// two places: the boot self-test and some directed ones, assembled, and
// random programs built with csp::ProgramBuilder as the firmware will build
// them — scalar ones; vector loops are #236's.
//
//   make sim-csp-cosim            (rtl/Makefile)
//   obj_dir/csp_cosim/sim [seed] [programs]     (default: seed 1, 200 programs)

#include <algorithm>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "assembler.hpp"
#include "csp/program_builder.hpp"
#include "processor.hpp"
#include "svdpi.h"
#include "verilated.h"

#include "csp_rtl.hpp"

namespace {

struct FirmwareWrite {
    int address;
    int32_t raw;
};

int failures = 0;

// ---- one run: a program on both, pass by pass ----------------------------------------------

class CoSim {
public:
    explicit CoSim(VerilatedContext &context) : rtl_(context) {}

    // Load the program and apply the setup while held, then release. The FIFO
    // holds 511 and the window takes 48 a pass, so the setup goes in chunks,
    // a swap and enough held passes to land each.
    void start(const csp::Image &image, const std::vector<FirmwareWrite> &setup) {
        constexpr size_t chunk = 96;
        rtl_.hold(true);
        rtl_.load(image);
        model_.load(image);
        run_pass({}, "the first pass");
        size_t done = 0;
        while (done < setup.size()) {
            const size_t end = std::min(setup.size(), done + chunk);
            for (; done < end; ++done) {
                rtl_.write(setup[done].address, setup[done].raw);
                model_.write(setup[done].address, setup[done].raw);
            }
            rtl_.swap();
            model_.swap();
            for (size_t landing = 0; landing <= chunk / csp::write_window + 1; ++landing) run_pass({}, "setup");
        }
        rtl_.hold(false);
        model_.release();
    }

    // One pass, after queueing writes and swapping (if any). Returns the
    // number of differences, printing the first few.
    int run_pass(const std::vector<FirmwareWrite> &writes, const std::string &what) {
        for (const FirmwareWrite &write : writes) {
            rtl_.write(write.address, write.raw);
            model_.write(write.address, write.raw);
        }
        if (!writes.empty()) {
            rtl_.swap();
            model_.swap();
        }
        rtl_.pass();
        const csp::PassReport report = model_.pass();
        ++passes_run;
        for (const std::string &error : report.errors) {
            std::printf("  %s: the model reports: %s\n", what.c_str(), error.c_str());
            ++model_errors;
            return 1;
        }
        return compare(what, report);
    }

    static inline int passes_run   = 0;
    static inline int model_errors = 0;

    void trace(bool on) { model_.trace(on); }
    int32_t reg(int address) const { return rtl_.reg(address); }
    int sink(int offset) const { return rtl_.sink(offset); }
    int cycles() const { return rtl_.cycles(); }

private:
    int compare(const std::string &what, const csp::PassReport &report) {
        int differences = 0;
        auto note       = [&](const std::string &where, int64_t rtl, int64_t model) {
            if (differences < 8) {
                std::printf("  %s: %s rtl %" PRId64 " model %" PRId64 "\n", what.c_str(), where.c_str(), rtl, model);
            }
            ++differences;
        };
        for (int address = 0; address < csp::register_count; ++address) {
            if (rtl_.reg(address) != model_.read(address)) {
                char where[32];
                std::snprintf(where, sizeof where, "register 0x%03x", address);
                note(where, rtl_.reg(address), model_.read(address));
            }
        }
        for (int offset = 0; offset < csp::sink_count; ++offset) {
            if (rtl_.sink(offset) != model_.sink(offset)) {
                char where[32];
                std::snprintf(where, sizeof where, "sink 0x%03x", offset);
                note(where, rtl_.sink(offset), model_.sink(offset));
            }
        }
        if (rtl_.index(0) != model_.index(csp::IndexRegister::i)) note("i", rtl_.index(0), model_.index(csp::IndexRegister::i));
        if (rtl_.index(1) != model_.index(csp::IndexRegister::j)) note("j", rtl_.index(1), model_.index(csp::IndexRegister::j));
        if (rtl_.accumulator() != model_.accumulator()) note("accumulator", rtl_.accumulator(), model_.accumulator());
        const csp::Flags flags = model_.flags();
        const int model_flags  = (flags.negative ? 1 : 0) | (flags.zero ? 2 : 0) | (flags.overflow ? 4 : 0);
        if (rtl_.flags() != model_flags) note("flags", rtl_.flags(), model_flags);
        if (rtl_.cycles() != report.cycles) note("cycles", rtl_.cycles(), report.cycles);
        if (rtl_.row_rule_violations() != 0) note("row rule violations", rtl_.row_rule_violations(), 0);
        if (rtl_.fifo_dropped() != 0) note("FIFO drops", rtl_.fifo_dropped(), 0);
        return differences;
    }

    Rtl rtl_;
    csp::Processor model_;
};

// ---- directed programs: assembled ------------------------------------------------------------

#ifndef CSP_PROGRAMS_DIR
#define CSP_PROGRAMS_DIR "../tools/csp/programs"
#endif

std::string program_file(const char *part) {
    std::ifstream file(std::string(CSP_PROGRAMS_DIR) + "/" + part);
    if (!file) {
        std::printf("cannot read %s\n", part);
        std::exit(2);
    }
    std::stringstream text;
    text << file.rdbuf();
    return text.str() + "\n";
}

int word_of(double value) {
    return static_cast<int>(std::lround(value * 16384.0));
}

const char *registers = R"(
        .reg A_, 0x060
        .reg B_, 0x061
        .reg C_, 0x062
        .reg D_, 0x063
        .wide W_, 0x064
        .wide V_, 0x066
        .reg S_, 0x068
        .reg T_, 0x069
        .block ITEM
        .field X, 1
        .field Y, 1
        .field Z, 1
        .field SPARE, 5
        .end
)";

struct Directed {
    const char *name;
    std::string source;
    int passes;
};

// The setup every program starts from: modest words in the registers it may read.
std::vector<FirmwareWrite> directed_setup() {
    std::vector<FirmwareWrite> setup;
    std::mt19937 random(11);
    for (int address = 0x001; address < 0x100; ++address) {
        setup.push_back({address, static_cast<int32_t>(random() % 60000) - 30000});
    }
    for (int item = 0; item < 16; ++item) {
        setup.push_back({0x200 + 8 * item, word_of(0.125 * (item - 8))});
        setup.push_back({0x200 + 8 * item + 1, word_of(0.0625 * item)});
    }
    return setup;
}

int run_image(VerilatedContext &context, const char *name, const csp::Program &program, int passes,
              const std::vector<FirmwareWrite> &setup, bool trace = false) {
    for (const csp::Diagnostic &d : program.diagnostics) {
        if (d.error) {
            std::printf("%s, line %d: %s\n", name, d.line, d.message.c_str());
            return 1;
        }
    }
    CoSim cosim(context);
    cosim.start(program.image, setup);
    cosim.trace(trace);
    int differences = 0;
    for (int pass = 1; pass <= passes && differences == 0; ++pass) {
        differences += cosim.run_pass({}, std::string(name) + " pass " + std::to_string(pass));
    }
    std::printf("%s: %s (%d rows, %d cycles a pass)\n", name, differences == 0 ? "ok" : "DIFFERS", program.image.length,
                program.cycles);
    return differences;
}

void run_directed(VerilatedContext &context) {
    const std::vector<FirmwareWrite> setup = directed_setup();
    const std::string map = program_file("map.s");
    const std::vector<Directed> programs = {
        {"selftest", map + program_file("selftest.s"), 24},
        // the chip check's one-path programs (tools/csp/programs/checks, #235): the scalar loops'
        // repeat, one vector loop, the wide pair's write and read
        {"loop", program_file("checks/loop.s"), 24},
        {"vloop", program_file("checks/vloop.s"), 24},
        {"vector_flags", program_file("checks/vector_flags.s"), 24},
        {"vector_back_to_back", program_file("checks/vector_back_to_back.s"), 24},
        {"pair", program_file("checks/pair.s"), 24},
        {"arithmetic", std::string(registers) + R"(
            MAC     A_, 0, B_, C_
            MAC     D_, D_, A_, =0.5
            INTERP  C_, C_, B_, D_
            ADD3    S_, 0, A_, D_
            CMP     ZERO, S_, T_
            SEL     T_, A_, B_
            MACW    A_, A_, =3.0, B_
            ACC     0, A_, B_
            ACC     acc, C_, D_
            MAC     B_, acc, =1.0, =1.0
            MIN     S_, A_, B_
            MAX     T_, C_, D_
            ABS     C_, D_
            ANDXOR  D_, D_, A_, B_
            SHIFT   S_, S_, C_
            SHIFT   T_, 0, =#-3
)", 4},
        {"wide", std::string(registers) + R"(
            MAC.w    W_, A_, V_
            MACW.w   V_, B_, W_
            INTERP.w W_, C_, V_
            ADD3.w   V_, D_, W_
            SHIFT.w  W_, =#2
            MAC      A_, 0, W_, =0.25
)", 4},
        {"loops and index", std::string(registers) + R"(
            IDX    i, =#0x200, 0
            LOOP.i end_a, =#4, =#8
            MAC    [i+Z], 0, [i+Y], =0.5
            ADD3   [i+X], [i+X], =0.125, ZERO
end_a:
            IDX    j, =#0x240, 0
            IDX    i, =#0x200, 0
            LOOP.i end_b, =#3, =#8
            MAC    A_, A_, [i+Z], =0.25
            LOOP.j end_c, =#2, =#1
            ADD3   [j+0], [j+0], =0.5, ZERO
end_c:
end_b:
            MAC    B_, 0, A_, =2.0
            LOOP.i end_d, =#0, =#8
            MAC    C_, 0, =1.0, =1.0
end_d:
            MAC    D_, 0, B_, =1.0
)", 4},
        {"skip and select", std::string(registers) + R"(
            CMP    ZERO, A_, B_
            SKIP   neg, 2
            MAC    C_, 0, =1.0, A_
            MAC    D_, 0, =2.0, B_
            MAC    S_, S_, =0.5, C_
            CMP    ZERO, B_, A_
            SEL    T_, C_, D_
            IDX    i, =#0x200, 0
            LOOP.i end, =#4, =#8
            CMP    ZERO, [i+X], [i+Y]
            SKIP   pos, 1
            ADD3   [i+Z], [i+Z], =0.25, ZERO
            MAC    A_, A_, =0.0625, S_
end:
)", 4},
        {"sinks", std::string(registers) + R"(
            IDX    j, =#0x800, 0
            MAC    [j+0], 0, A_, =1.0
            ADD3   [j+1], 0, B_, C_
            CMP    [j+2], A_, B_
)", 4},
    };
    for (const Directed &directed : programs) {
        const csp::Program program = csp::assemble(directed.source);
        failures += run_image(context, directed.name, program, directed.passes, setup) != 0;
    }
}

// ---- random programs ----------------------------------------------------------------------------
//
// Built with csp::ProgramBuilder, as the firmware builds. The rules a program must keep to be valid
// (the model reports what it breaks): index registers point at 64-aligned blocks of the register
// file and a word is read at an offset below 32, so that the chip's OR is the sum; i and j are set
// before use and again after a loop steps them; nothing is written to an input; a SKIP and the rows
// it skips lie inside one loop body; and no row sets the index register of the loop it is in.

class Generator {
public:
    explicit Generator(uint32_t seed) : random_(seed) {}

    csp::ProgramBuilder::Built build() {
        csp::ProgramBuilder b;
        point(b, csp::IndexRegister::i);
        point(b, csp::IndexRegister::j);
        const int units = pick(4, 10);
        for (int unit = 0; unit < units; ++unit) {
            switch (pick(0, 9)) {
            case 0:
            case 1:
                loop(b, chance(2) ? csp::IndexRegister::i : csp::IndexRegister::j, 0);
                break;
            case 2:
                skip(b);
                break;
            case 3:
                sink_group(b);
                break;
            case 4:
                point(b, chance(2) ? csp::IndexRegister::i : csp::IndexRegister::j);
                break;
            default:
                instruction(b);
                break;
            }
        }
        return b.build();
    }

    std::vector<FirmwareWrite> setup() {
        std::vector<FirmwareWrite> writes;
        for (int address = 0x001; address < 0x800; ++address) {
            if (address >= csp::io_base && address < csp::io_base + csp::io_count) continue;
            writes.push_back({address, word()});
        }
        return writes;
    }

    std::vector<FirmwareWrite> firmware_writes() {
        std::vector<FirmwareWrite> writes;
        for (int n = pick(0, 6); n > 0; --n) writes.push_back({pick(0x060, 0x0FF), word()});
        return writes;
    }

private:
    int pick(int low, int high) { return std::uniform_int_distribution<int>(low, high)(random_); }
    bool chance(int one_in) { return pick(1, one_in) == 1; }

    int32_t word() {
        switch (pick(0, 7)) {
        case 0: return pick(-131072, 131071);
        case 1: return chance(2) ? 131071 : -131072;
        default: return pick(-40000, 40000);
        }
    }

    using Index = csp::IndexRegister;
    bool &valid(Index which) { return which == Index::i ? i_valid_ : j_valid_; }

    // IDX to a 64-aligned block of registers (or of sinks, for a sink group)
    void point(csp::ProgramBuilder &b, Index which, int base = -1) {
        if (base < 0) base = 0x100 + 64 * pick(0, 9);
        b.idx(which, csp::Source::imm(base), csp::Source::reg(csp::Operand::direct(0)));
        valid(which) = true;
    }

    csp::Operand direct(int address) { return csp::Operand::direct(address); }

    csp::Source word_source() {
        switch (pick(0, 11)) {
        case 0: return csp::Source::reg(direct(0));
        case 1:
        case 2: return csp::Source::reg(direct(pick(0x001, 0x02F)));
        case 3:
        case 4: return csp::Source::reg(indexed_or_direct(Index::i, 31));
        case 5:
        case 6: return csp::Source::reg(indexed_or_direct(Index::j, 31));
        case 7: return csp::Source::imm(word());
        default: return csp::Source::reg(direct(pick(0x060, 0x0DF)));
        }
    }

    csp::Operand indexed_or_direct(Index which, int span) {
        if (valid(which) && !sink_group_) return csp::Operand::indexed(which, pick(0, span));
        return direct(pick(0x060, 0x0DF));
    }

    csp::Operand result_operand() {
        switch (pick(0, 9)) {
        case 0: return direct(0);   // discarded
        case 1:
        case 2: return indexed_or_direct(Index::i, 31);
        case 3:
        case 4: return sink_group_ ? csp::Operand::indexed(Index::j, pick(0, 31)) : indexed_or_direct(Index::j, 31);
        default: return direct(pick(0x060, 0x0DF));
        }
    }

    csp::Operand wide_operand() {
        if (chance(4) && valid(Index::i) && !sink_group_) return csp::Operand::indexed(Index::i, 2 * pick(0, 15));
        return direct(0x0E0 + 2 * pick(0, 15));
    }

    csp::ASource a_source() {
        switch (pick(0, 3)) {
        case 0: return csp::ASource::zero;
        case 1: return csp::ASource::accumulator;
        default: return csp::ASource::result;
        }
    }

    // two sources, at most one of them an immediate
    void sources(csp::Source &x, csp::Source &y) {
        x = word_source();
        y = word_source();
        if (x.operand.mode == csp::Operand::Mode::immediate && y.operand.mode == csp::Operand::Mode::immediate) {
            y = csp::Source::reg(direct(pick(0x060, 0x0DF)));
        }
    }

    void instruction(csp::ProgramBuilder &b) {
        csp::Source x, y;
        sources(x, y);
        const csp::Operand r = result_operand();
        switch (pick(0, 14)) {
        case 0: b.mac(r, a_source(), x, y); break;
        case 1: b.macw(r, a_source(), x, y); break;
        case 2: b.interp(r, a_source(), x, y); break;
        case 3: b.add3(r, a_source(), x, y); break;
        case 4: b.acc(chance(2) ? csp::ASource::zero : csp::ASource::accumulator, x, y); break;
        case 5: b.sel(r, static_cast<csp::Condition>(pick(0, 5)), x, y); break;
        case 6: b.cmp(r, x, y); break;
        case 7: chance(2) ? b.min(r, x, y) : b.max(r, x, y); break;
        case 8: b.andxor(r, chance(2) ? csp::ASource::zero : a_source(), x, y); break;
        case 9: b.shift(r, a_source(), y); break;
        case 10: b.abs(r, x); break;
        case 11:
            if (!sink_group_) {
                const csp::Operand wide = wide_operand();
                const csp::Source y_wide = csp::Source::reg(wide_operand());
                switch (pick(0, 4)) {
                case 0: b.mac(wide, csp::ASource::result, x, y_wide, true); break;
                case 1: b.macw(wide, csp::ASource::result, x, y_wide, true); break;
                case 2: b.interp(wide, csp::ASource::result, x, y_wide, true); break;
                case 3: b.add3(wide, csp::ASource::result, x, y_wide, true); break;
                default: b.shift(wide, csp::ASource::result, y, true); break;
                }
                break;
            }
            [[fallthrough]];
        default: b.mac(r, a_source(), x, y); break;
        }
    }

    // a SKIP and the rows it skips, whole
    void skip(csp::ProgramBuilder &b) {
        const int count = pick(1, 3);
        b.skip(static_cast<csp::Condition>(pick(0, 5)), static_cast<size_t>(count));
        for (int n = 0; n < count; ++n) instruction(b);
    }

    // sinks are written through j, which points into the sink area for the group and reads nothing through it
    void sink_group(csp::ProgramBuilder &b) {
        point(b, Index::j, 0x800 + 64 * pick(0, 15));
        sink_group_ = true;
        for (int n = pick(1, 3); n > 0; --n) {
            csp::Source x, y;
            sources(x, y);
            const csp::Operand r = csp::Operand::indexed(Index::j, pick(0, 31));
            switch (pick(0, 3)) {
            case 0: b.mac(r, csp::ASource::zero, x, y); break;
            case 1: b.add3(r, csp::ASource::zero, x, y); break;
            case 2: b.cmp(r, x, y); break;
            default: b.max(r, x, y); break;
            }
        }
        sink_group_ = false;
        point(b, Index::j);
    }

    // a loop on `which`, its register pointed at a block beforehand, and its body free of IDX on that register;
    // an outer loop may hold an inner one on the other register
    void loop(csp::ProgramBuilder &b, Index which, int depth) {
        const int count  = chance(6) ? 0 : pick(1, 4);
        const int stride = pick(0, 2) == 0 ? 0 : (chance(2) ? 64 : -64);
        int base;
        if (stride >= 0) base = 0x100 + 64 * pick(0, 9 - std::max(count - 1, 0));
        else             base = 0x100 + 64 * (std::max(count - 1, 0) + pick(0, 9 - std::max(count - 1, 0)));
        if (depth == 0 || !loop_on_other_) point(b, which, base);
        const size_t at = b.open_loop(which, count, stride);
        const Index other = which == Index::i ? Index::j : Index::i;
        const int body = pick(1, 4);
        for (int n = 0; n < body; ++n) {
            if (depth == 0 && chance(6) && n + 1 < body) {
                // an inner loop on the other register, its block pointed inside this body
                const bool saved = valid(other);
                point(b, other);
                loop_on_other_ = true;
                const int inner_count = chance(6) ? 0 : pick(1, 3);
                const size_t inner = b.open_loop(other, inner_count, 0);
                for (int m = pick(1, 2); m > 0; --m) instruction(b);
                b.close_loop(inner);
                loop_on_other_ = false;
                valid(other) = false;   // stepped by the loop (stride 0 keeps it, but be strict)
                (void) saved;
            } else if (chance(8)) {
                skip(b);
            } else {
                instruction(b);
            }
        }
        b.close_loop(at);
        valid(which) = false;           // stepped past its block
        point(b, which);
        if (valid(other) && depth == 0) { /* unchanged */ }
    }

    std::mt19937 random_;
    bool i_valid_ = false, j_valid_ = false;
    bool sink_group_ = false, loop_on_other_ = false;
};

void run_random(VerilatedContext &context, uint32_t seed, int programs) {
    int built = 0, differing = 0, rejected = 0;
    for (int program = 0; program < programs; ++program) {
        Generator generator(seed * 100003u + static_cast<uint32_t>(program));
        const csp::ProgramBuilder::Built result = generator.build();
        if (!result.ok) {
            ++rejected;   // too long for a pass, or a rule the generator broke: not a case
            continue;
        }
        ++built;
        CoSim cosim(context);
        csp::Image image = result.image;
        cosim.start(image, generator.setup());
        int differences = 0;
        for (int pass = 1; pass <= 4 && differences == 0; ++pass) {
            differences += cosim.run_pass(pass == 1 ? std::vector<FirmwareWrite>{} : generator.firmware_writes(),
                                          "random " + std::to_string(program) + " pass " + std::to_string(pass));
        }
        if (differences != 0) {
            ++differing;
            ++failures;
            std::printf("random program %d (seed %u) DIFFERS: %d rows, %d cycles\n", program, seed, image.length, result.cycles);
            if (differing >= 5) break;
        }
    }
    std::printf("random: %d programs built, %d rejected by the builder, %d differ\n", built, rejected, differing);
}

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    const uint32_t seed = argc > 1 && argv[1][0] != '+' ? static_cast<uint32_t>(std::atoi(argv[1])) : 1;
    const int programs  = argc > 2 && argv[2][0] != '+' ? std::atoi(argv[2]) : 200;
    run_directed(context);
    run_random(context, seed, programs);
    std::printf("\n%d passes compared on both\n", CoSim::passes_run);
    if (failures == 0 && CoSim::model_errors == 0) {
        std::printf("ALL PASS\n");
        return 0;
    }
    std::printf("%d FAILURE(S), %d model errors\n", failures, CoSim::model_errors);
    return 1;
}
