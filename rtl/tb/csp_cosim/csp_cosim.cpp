// csp_cosim.cpp — the new CSP's RTL against tools/csp's reference model
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Runs the same programs and firmware writes on the RTL (Verilated
// tb_csp_cosim.sv) and on the reference model, and after every pass
// compares everything a program can leave behind: all 2048 registers, the
// published sink page, i, j, the accumulator and the flags. Programs come
// from two places: the manual's examples, assembled, and random programs
// built with csp::ProgramBuilder, as the firmware will build them.
//
//   make sim-csp-cosim            (rtl/Makefile)
//   obj_dir/csp_cosim/sim [seed] [programs]     (default: seed 1, 200 programs)

#include <cinttypes>
#include <cstdio>
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "assembler.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "csp/program_builder.hpp"
#include "processor.hpp"
#include "svdpi.h"
#include "verilated.h"

#include "csp_rtl.hpp"

namespace {

// ---- one run: a program on both, pass by pass ----------------------------------------------

struct FirmwareWrite {
    int address;
    int32_t raw;
};

class CoSim {
public:
    explicit CoSim(VerilatedContext &context) : rtl_(context) {}

    // Load the program and apply the setup while held, then release. The write
    // queue holds 512 writes, so a large setup goes in chunks, a swap and a
    // held pass for each.
    void start(const std::vector<uint64_t> &words,
               const std::vector<FirmwareWrite> &setup) {
        constexpr size_t chunk = 256;
        rtl_.hold(true);
        rtl_.load(words);
        model_.load(words);
        size_t done = 0;
        do {
            const size_t end = std::min(setup.size(), done + chunk);
            for (; done < end; ++done) {
                rtl_.write(setup[done].address, setup[done].raw);
                model_.write(setup[done].address, setup[done].raw);
            }
            rtl_.swap();
            model_.swap();
            rtl_.pass();
            model_.pass(); // held: applies the chunk
        } while (done < setup.size());
        rtl_.hold(false);
        model_.release();
    }

    // One pass, after queueing writes and swapping (if any). Returns the
    // number of differences, printing the first few.
    int pass(const std::vector<FirmwareWrite> &writes,
             const std::string &what) {
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
        if (!report.errors.empty() && verbose_) {
            std::printf("  (model: %s)\n", report.errors.front().c_str());
        }
        // A pass the model stopped at the limit ends in a state the
        // hardware has no way to match: the model finishes the loop it was
        // in, the RTL stops issuing. Registers and sinks still have to agree.
        bool stopped_at_limit = false;
        for (const std::string &error : report.errors) {
            stopped_at_limit |= error.rfind("pass longer", 0) == 0;
        }
        ++passes_run;
        passes_at_limit += stopped_at_limit;
        int differences = compare(what, !stopped_at_limit);
        // The interlocks' timing: the RTL issues its last instruction in the
        // cycle the model counts. (A pass the model stopped at the limit
        // ends differently: the RTL runs on through memory past the
        // program, which may hold anything.)
        if (report.errors.empty() && rtl_.cycles() != report.cycles) {
            std::printf("  %s: cycles rtl %d model %d\n", what.c_str(),
                        rtl_.cycles(), report.cycles);
            ++differences;
        }
        return differences;
    }

    // How many passes ran, and how many of those the model stopped at the
    // pass limit (their end state is not compared).
    static inline int passes_run      = 0;
    static inline int passes_at_limit = 0;

    // What the RTL has published and how long its last pass took, for a
    // case to say it did something.
    int sink(int offset) const {
        return rtl_.sink(offset);
    }
    int cycles() const {
        return rtl_.cycles();
    }

    void verbose(bool on) {
        verbose_ = on;
    }

    void trace(bool on) {
        model_.trace(on);
    }

private:
    int compare(const std::string &what, bool compare_control_state) {
        int differences = 0;
        auto report     = [&](const std::string &where, int64_t rtl,
                          int64_t model) {
            if (differences < 8) {
                std::printf("  %s: %s rtl %" PRId64 " model %" PRId64 "\n",
                                what.c_str(), where.c_str(), rtl, model);
            }
            ++differences;
        };
        for (int address = 0; address < csp::register_count; ++address) {
            if (rtl_.reg(address) != model_.read(address)) {
                char where[32];
                std::snprintf(where, sizeof where, "register 0x%03x", address);
                report(where, rtl_.reg(address), model_.read(address));
            }
        }
        for (int offset = 0; offset < csp::sink_count; ++offset) {
            if (rtl_.sink(offset) != model_.sink(offset)) {
                char where[32];
                std::snprintf(where, sizeof where, "sink 0x%03x", offset);
                report(where, rtl_.sink(offset), model_.sink(offset));
            }
        }
        if (!compare_control_state) {
            return differences;
        }
        if (rtl_.index(0) != model_.index(csp::IndexRegister::i)) {
            report("i", rtl_.index(0), model_.index(csp::IndexRegister::i));
        }
        if (rtl_.index(1) != model_.index(csp::IndexRegister::j)) {
            report("j", rtl_.index(1), model_.index(csp::IndexRegister::j));
        }
        if (rtl_.accumulator() != model_.accumulator()) {
            report("accumulator", rtl_.accumulator(), model_.accumulator());
        }
        const csp::Flags flags = model_.flags();
        const int model_flags  = (flags.negative ? 1 : 0) | (flags.zero ? 2 : 0)
                                | (flags.overflow ? 4 : 0);
        if (rtl_.flags() != model_flags) {
            report("flags", rtl_.flags(), model_flags);
        }
        return differences;
    }

    Rtl rtl_;
    csp::Processor model_;
    bool verbose_ = false;
};

// ---- directed programs: the manual's examples ------------------------------------------------
// The envelope, as LOOP.i and as LOOP.vi (U becomes a voice field).

const char *envelope_program = R"(
        .block VOICE
        .field LEVEL, 2
        .field STAGE, 1
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .end
        .block SEGMENT
        .field TARGET, 2
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ   VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060
        .reg   U, 0x061

        IDX     i, =#VOICES, 0
        NOP
        NOP
        NOP
        LOOP.i  done, =#4, =#16
        IDX     j, ENV_TABLE, [i+STAGE]
        MAX     U, [i+STAGE], =#4
        CMP     ZERO, [i+LEVEL], FULL
        SEL     [i+STAGE], U, [i+STAGE]
        ANDXOR  U, 0, [i+STAGE], =#4
        CMP     ZERO, [i+GATE], FULL
        SEL     [i+STAGE], U, =#8
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
done:
        IDX     j, =#0x800, 0
        NOP
        NOP
        NOP
        MAC     [j+0], 0, [i+0], =1.0       ; i is past the voices: a sink write
)";

const char *envelope_vector_program = R"(
        .block VOICE
        .field LEVEL, 2
        .field STAGE, 1
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .field U, 1
        .end
        .block SEGMENT
        .field TARGET, 2
        .field RATE, 1
        .field SPARE, 1
        .end
        .equ   VOICES, 0x600
        .const FULL, 1.0
        .reg   ENV_TABLE, 0x060

        IDX     i, =#VOICES, 0
        NOP
        NOP
        NOP
        LOOP.vi done, =#4, =#16
        IDX     j, ENV_TABLE, [i+STAGE]
        MAX     [i+U], [i+STAGE], =#4
        CMP     ZERO, [i+LEVEL], FULL
        SEL     [i+STAGE], [i+U], [i+STAGE]
        ANDXOR  [i+U], 0, [i+STAGE], =#4
        CMP     ZERO, [i+GATE], FULL
        SEL     [i+STAGE], [i+U], =#8
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
done:
        IDX     j, =#0x800, 0
        NOP
        NOP
        NOP
        MAC     [j+0], 0, [i+0], =1.0       ; i is past the voices: a sink write
)";

const char *lfo_program = R"(
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

        MACW.w  PHASE, ONE, RATE
        MAC     SAW, 0, PHASE, DEPTH_8
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, NEG_DEPTH, DEPTH
        ABS     T, PHASE
        MAC     TRI, 0, T, DEPTH_4
        ADD3    TRI, TRI, NEG_DEPTH, ZERO
        SHIFT   T, T, =#-3
        ACC     0, SAW, =0.5
        ACC     acc, SQUARE, =0.5
        MAC     0x068, acc, TRI, =0.5
)";

std::vector<FirmwareWrite> constants_of(const csp::Program &program) {
    std::vector<FirmwareWrite> writes;
    for (const csp::ConstantWrite &constant : program.constants) {
        writes.push_back({constant.address, constant.raw});
    }
    return writes;
}

// ---- the control program ------------------------------------------------------------------
//
// tools/csp/programs, the whole of it on the RTL and the model: 16 channels,
// 32 voices with both envelopes, 32 LFOs of every shape, notes struck and
// released while it runs.

#ifndef CSP_PROGRAMS_DIR
#define CSP_PROGRAMS_DIR "../tools/csp/programs"
#endif

std::string control_program_text() {
    std::string source;
    for (const char *part :
         {"map.s", "lfo.s", "channel.s", "envelope.s", "voice.s"}) {
        std::ifstream file(std::string(CSP_PROGRAMS_DIR) + "/" + part);
        if (!file) {
            std::printf("cannot read %s\n", part);
            std::exit(2);
        }
        std::stringstream text;
        text << file.rdbuf();
        source += text.str() + "\n";
    }
    return source;
}

void write_wide_words(std::vector<FirmwareWrite> &writes, int address,
                      int64_t raw36) {
    writes.push_back({address, static_cast<int32_t>((raw36 >> 18) & 0x3FFFF)});
    writes.push_back({address + 1, static_cast<int32_t>(raw36 & 0x3FFFF)});
}

int word_of(double value) {
    return static_cast<int>(std::lround(value * 16384.0));
}

int run_control_program(VerilatedContext &context) {
    const csp::Program program = csp::assemble(control_program_text());
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::printf("control program, line %d: %s\n", d.line,
                    d.message.c_str());
        if (d.error) {
            return 1;
        }
    }
    auto symbol = [&](const char *name) {
        return program.symbols.at(name);
    };
    const int channels     = symbol("CHANNELS"),
              channel_size = symbol("CHANNEL_SIZE");
    const int voices = symbol("VOICES"), voice_size = symbol("VOICE_SIZE");
    const int lfos = symbol("LFOS"), lfo_size = symbol("LFO_SIZE");
    const int sinks = symbol("SINKS");

    std::vector<FirmwareWrite> setup = constants_of(program);
    std::mt19937 random(7);
    auto pick = [&](int low, int high) {
        return std::uniform_int_distribution<int>(low, high)(random);
    };

    // The LFOs: each half of the pool sorted by shape (3 saws, 4 squares,
    // 4 triangles, 5 sines), two sets
    const int counts[4] = {3, 4, 4, 5};
    for (int half = 0; half < 2; ++half) {
        const int set = symbol("LFO_SETS") + half * symbol("SET_SIZE");
        setup.push_back({set + symbol("BASE"), lfos + half * 16 * lfo_size});
        for (int shape = 0; shape < 4; ++shape) {
            setup.push_back({set + symbol("N_SAW") + shape, counts[shape]});
        }
        int slot = half * 16;
        for (int shape = 0; shape < 4; ++shape) {
            for (int n = 0; n < counts[shape]; ++n, ++slot) {
                const int record   = lfos + slot * lfo_size;
                const double depth = 0.25 * pick(1, 8);
                write_wide_words(setup, record + symbol("PHASE"),
                                 int64_t{pick(0, 1 << 30)} << 6);
                write_wide_words(setup, record + symbol("PHASE_STEP"),
                                 csp::lfo_rate(pick(30, 12000), 2));
                setup.push_back({record + symbol("DEPTH"), word_of(depth)});
                setup.push_back(
                        {record + symbol("NEG_DEPTH"), word_of(-depth)});
                setup.push_back({record + symbol("GAIN"),
                                 shape == 0   ? word_of(depth / 8)
                                 : shape == 2 ? word_of(depth / 4)
                                              : 0});
            }
        }
    }
    // The channels: envelope tables, routing, depths
    const int channel_sinks = symbol("CHANNEL_SINKS");
    const int sink_size     = symbol("CHANNEL_SINK_SIZE");
    setup.push_back({symbol("CHANNELS_IN_USE"), 16});
    for (int channel = 0; channel < 16; ++channel) {
        const int base = channels + channel * channel_size;
        auto table     = [&](int row, int64_t target22, uint32_t coefficient) {
            write_wide_words(setup, base + row, target22 << 10);
            write_wide_words(setup, base + row + 2,
                                 csp::envelope_rate(coefficient));
        };
        for (int kind = 0; kind < 2; ++kind) {
            const int row = 16 * kind;
            table(row + 0, 0x533333, pick(500, 60000));
            table(row + 4, int64_t{pick(100, 1000)} << 12, pick(100, 20000));
            table(row + 8, 0, pick(60, 8000));
        }
        auto field = [&](const char *name, int raw) {
            setup.push_back({base + symbol(name), raw});
        };
        field("BEND", word_of(0.01 * pick(-12, 12)));
        field("LFO1_PITCH", word_of(0.01 * pick(0, 30)));
        field("LFO1_CUTOFF", word_of(0.1 * pick(-10, 10)));
        field("LFO2_PITCH", word_of(0.01 * pick(0, 30)));
        field("LFO2_CUTOFF", word_of(0.1 * pick(-10, 10)));
        field("LFO1", lfos + pick(0, 31) * lfo_size);
        field("LFO2", lfos + pick(0, 31) * lfo_size);
        field("CUTOFF_BASE", word_of(0.1 * pick(0, 40)));
        field("KEY_TRACK", word_of(0.25 * pick(0, 6)));
        field("MOD_AMOUNT", word_of(0.1 * pick(-30, 30)));
        field("VOLUME", word_of(0.1 * pick(2, 10)));
        field("LFO1_DUTY", word_of(0.01 * pick(0, 30)));
        field("LFO2_DUTY", word_of(0.01 * pick(0, 30)));
        field("LFO1_RESONANCE", word_of(0.1 * pick(0, 10)));
        field("LFO2_RESONANCE", word_of(0.1 * pick(0, 10)));
        field("DUTY_BASE_0", word_of(0.1 * pick(-5, 5)));
        field("DUTY_BASE_1", word_of(0.1 * pick(-5, 5)));
        field("RESONANCE_BASE", word_of(0.1 * pick(0, 40)));
        field("SINK_BLOCK", channel_sinks + channel * sink_size);
    }
    // The voices: idle, in release
    for (int voice = 0; voice < 32; ++voice) {
        const int base = voices + voice * voice_size;
        setup.push_back({base + symbol("STAGE_A"), 8});
        setup.push_back({base + symbol("STAGE_M"), 24});
        setup.push_back(
                {base + symbol("VELOCITY"), word_of(0.1 * pick(3, 10))});
        setup.push_back(
                {base + symbol("VELOCITY_M"), word_of(0.1 * pick(3, 10))});
        setup.push_back({base + symbol("CHANNEL"),
                         channels + pick(0, 15) * channel_size});
        setup.push_back({base + symbol("NOTE"), word_of(0.1 * pick(-20, 20))});
        setup.push_back({base + symbol("SINK"), sinks + 8 * voice});
    }

    CoSim cosim(context);
    cosim.start(program.words, setup);
    int differences      = 0;
    constexpr int passes = 400;
    int most_cycles      = 0;
    for (int pass = 0; pass < passes && differences == 0; ++pass) {
        std::vector<FirmwareWrite> writes;
        for (int voice = 0; voice < 32; ++voice) {
            const int base = voices + voice * voice_size;
            if (pass == 3 + 5 * voice) { // struck
                write_wide_words(writes, base + symbol("LEVEL_A"), 0);
                write_wide_words(writes, base + symbol("LEVEL_M"), 0);
                writes.push_back({base + symbol("GATE"), 16384});
            } else if (pass == 190 + 4 * voice) { // released
                writes.push_back({base + symbol("GATE"), 0});
            }
        }
        differences = cosim.pass(writes, "control program pass "
                                                 + std::to_string(pass));
        most_cycles = std::max(most_cycles, cosim.cycles());
    }
    int live = 0; // sink words that are not 0 at the end
    for (int voice = 0; voice < 32; ++voice) {
        for (int word = 0; word < 3; ++word) {
            live += cosim.sink((sinks - csp::sink_base) + 8 * voice + word)
                    != 0;
        }
    }
    std::printf("control program: %d passes, at most %d cycles a pass, "
                "%d of 96 voice sinks live\n",
                passes, most_cycles, live);
    return differences;
}

// ---- random programs ---------------------------------------------------------------------------
//
// Register plan: constants 0x001–0x03F (random values, set by the
// firmware), with loop counts and strides at fixed places; work words
// 0x060–0x0DF; wide pairs 0x0E0–0x0FF; i starts at 0x200, j at 0x300
// (blocks the programs index into), or at 0x800 for sink writes.

constexpr int count_base  = 0x030; // 0x030–0x033: loop counts 1–4
constexpr int stride_base = 0x034; // 0x034–0x037: strides 2, 4, −2, 16
constexpr int base_i      = 0x038; // holds 0x200
constexpr int base_j      = 0x039; // holds 0x300
constexpr int base_sink   = 0x03A; // holds 0x800
constexpr int count_nine =
        0x03B; // holds 9: more elements than a wait takes cycles
constexpr int count_zero = 0x03C; // holds 0: a loop that runs its body no times

class Generator {
public:
    explicit Generator(uint32_t seed) : random_(seed) {}

    std::vector<FirmwareWrite> setup() {
        std::vector<FirmwareWrite> writes;
        for (int address = 0x001; address < count_base; ++address) {
            writes.push_back({address, word()});
        }
        for (int count = 0; count < 4; ++count) {
            writes.push_back({count_base + count, count + 1});
        }
        const int strides[] = {2, 4, -2, 16};
        for (int n = 0; n < 4; ++n) {
            writes.push_back({stride_base + n, strides[n]});
        }
        writes.push_back({base_i, 0x200});
        writes.push_back({base_j, 0x300});
        writes.push_back({base_sink, 0x800});
        writes.push_back({count_nine, 9});
        writes.push_back({count_zero, 0});
        for (int address = 0x060; address < 0x100; ++address) {
            writes.push_back({address, word()});
        }
        return writes;
    }

    // A few writes, or now and then a burst past the 48-write window that
    // includes writes the window must drop (register 0, the inputs).
    std::vector<FirmwareWrite> writes_between_passes() {
        std::vector<FirmwareWrite> writes;
        const bool burst = chance(6);
        const int count  = burst ? pick(50, 70) : pick(0, 6);
        for (int n = 0; n < count; ++n) {
            int address = pick(0x060, 0x0FF);
            if (burst && chance(8)) {
                address = chance(2) ? 0 : pick(0x040, 0x05F);
            } else if (chance(5)) {
                address = pick(0x800, 0xBFF); // a sink word: the firmware's own
            } else if (chance(40)) {
                address = pick(0xC00, 0xFFF); // beyond the sinks: dropped
            }
            writes.push_back({address, word()});
        }
        return writes;
    }

    std::vector<uint64_t> program() {
        csp::ProgramBuilder b;
        b.idx(csp::IndexRegister::i, direct(base_i), direct(0));
        b.idx(csp::IndexRegister::j, direct(chance(4) ? base_sink : base_j),
              direct(0));
        const int items = pick(10, 60);
        for (int item = 0; item < items; ++item) {
            const int kind = pick(0, 21);
            if (kind == 0) {
                loop(b, true);
            } else if (kind == 20 || kind == 21) {
                vector_loop(b);
            } else if (kind == 1) {
                skip(b);
            } else {
                instruction(b, false);
            }
        }
        return b.words();
    }

private:
    int pick(int low, int high) {
        return std::uniform_int_distribution<int>(low, high)(random_);
    }
    bool chance(int one_in) {
        return pick(1, one_in) == 1;
    }
    int32_t word() {
        // mostly modest values, sometimes the extremes
        switch (pick(0, 7)) {
        case 0:
            return pick(-131072, 131071);
        case 1:
            return chance(2) ? 131071 : -131072;
        default:
            return pick(-40000, 40000);
        }
    }

    static csp::Operand direct(int address) {
        return csp::Operand::direct(address);
    }

    csp::Operand word_operand() {
        switch (pick(0, 9)) {
        case 0:
            return direct(0);
        case 1:
        case 2:
            return direct(pick(0x001, 0x02F)); // constants
        case 3:
            return csp::Operand::indexed(csp::IndexRegister::i, pick(0, 31));
        case 4:
            return csp::Operand::indexed(csp::IndexRegister::j, pick(0, 31));
        default:
            return direct(pick(0x060, 0x0DF));
        }
    }

    csp::Operand result_operand() {
        switch (pick(0, 9)) {
        case 0:
            return direct(0); // discarded
        case 1:
            return csp::Operand::indexed(csp::IndexRegister::i, pick(0, 31));
        case 2:
        case 3:
            return csp::Operand::indexed(csp::IndexRegister::j, pick(0, 31));
        default:
            return direct(pick(0x060, 0x0DF));
        }
    }

    csp::Operand wide_operand() {
        switch (pick(0, 5)) {
        case 0:
            return csp::Operand::indexed(csp::IndexRegister::i,
                                         2 * pick(0, 15));
        default:
            return direct(0x0E0 + 2 * pick(0, 15));
        }
    }

    csp::ASelect a_select() {
        switch (pick(0, 3)) {
        case 0:
            return csp::ASelect::zero;
        case 1:
            return csp::ASelect::accumulator;
        default:
            return csp::ASelect::result;
        }
    }

    void instruction(csp::ProgramBuilder &b, bool in_loop) {
        const csp::Operand x = word_operand();
        const csp::Operand y = word_operand();
        switch (pick(0, 15)) {
        case 0:
            b.mac(result_operand(), a_select(), x, y);
            break;
        case 1:
            b.macw(result_operand(), a_select(), x, y);
            break;
        case 2:
            b.interp(result_operand(), a_select(), x, y);
            break;
        case 3:
            b.add3(result_operand(), a_select(), x, y);
            break;
        case 4:
            b.acc(chance(2) ? csp::ASelect::zero : csp::ASelect::accumulator, x,
                  y);
            break;
        case 5:
            b.sel(result_operand(), x, y);
            break;
        case 6:
            b.cmp(result_operand(), x, y);
            break;
        case 7:
            chance(2) ? b.min(result_operand(), x, y)
                      : b.max(result_operand(), x, y);
            break;
        case 8:
            b.andxor(result_operand(),
                     chance(2) ? csp::ASelect::zero : a_select(), x, y);
            break;
        case 9:
            b.shift(result_operand(), a_select(), direct(pick(0x001, 0x02F)));
            break;
        case 10:
            b.abs(result_operand(), x);
            break;
        case 11: {
            const csp::Operand wide = wide_operand();
            switch (pick(0, 4)) {
            case 0:
                b.mac_wide(wide, x, wide_operand());
                break;
            case 1:
                b.macw_wide(wide, x, wide_operand());
                break;
            case 2:
                b.interp_wide(wide, x, wide_operand());
                break;
            case 3:
                b.add3_wide(wide, x, wide_operand());
                break;
            default:
                b.shift_wide(wide, direct(pick(0x001, 0x02F)));
                break;
            }
            break;
        }
        case 12:
            if (!in_loop) {
                // re-point i or j at its block, or somewhere random
                const bool on_j = chance(2);
                b.idx(on_j ? csp::IndexRegister::j : csp::IndexRegister::i,
                      direct(chance(3) ? pick(0x060, 0x0DF)
                                       : (on_j ? base_j : base_i)),
                      y);
                break;
            }
            [[fallthrough]];
        default:
            b.mac(result_operand(), a_select(), x, y);
            break;
        }
    }

    void skip(csp::ProgramBuilder &b) {
        const auto condition = static_cast<csp::Condition>(pick(0, 5));
        const int count      = pick(1, 3);
        b.skip(condition, static_cast<size_t>(count));
        for (int n = 0; n < count; ++n) {
            instruction(b, false);
        }
    }

    // ---- vector loops ---------------------------------------------------------------------
    // A vector loop's iterations must not share registers, so a body writes
    // only the element's own block ([own+k], k < 16, a stride of 16) and
    // reads constants, registers nothing in the body writes, that block, and
    // the table the element's private index register points at.
    static csp::IndexRegister other_index(csp::IndexRegister own) {
        return own == csp::IndexRegister::i ? csp::IndexRegister::j
                                            : csp::IndexRegister::i;
    }

    csp::Operand block_operand(csp::IndexRegister own) {
        return csp::Operand::indexed(own, pick(0, 15));
    }

    csp::Operand vector_read(csp::IndexRegister own) {
        switch (pick(0, 8)) {
        case 0:
            return direct(0);
        case 1:
        case 2:
            return direct(pick(0x001, 0x02F));
        case 3:
            return direct(pick(0x060, 0x0DF));
        case 4:
        case 5:
            return csp::Operand::indexed(other_index(own), pick(0, 15));
        default:
            return block_operand(own);
        }
    }

    csp::ASelect vector_a_select() {
        return chance(2) ? csp::ASelect::zero : csp::ASelect::result;
    }

    void vector_instruction(csp::ProgramBuilder &b, csp::IndexRegister own) {
        const csp::Operand r = chance(8) ? direct(0) : block_operand(own);
        const csp::Operand x = vector_read(own);
        const csp::Operand y = vector_read(own);
        switch (pick(0, 13)) {
        case 0:
            b.mac(r, vector_a_select(), x, y);
            break;
        case 1:
            b.macw(r, vector_a_select(), x, y);
            break;
        case 2:
            b.interp(r, vector_a_select(), x, y);
            break;
        case 3:
            b.add3(r, vector_a_select(), x, y);
            break;
        case 4:
        case 5:
            b.cmp(r, x, y);
            break;
        case 6:
        case 7:
            b.sel(r, x, y);
            break;
        case 8:
            chance(2) ? b.min(r, x, y) : b.max(r, x, y);
            break;
        case 9:
            b.andxor(r, vector_a_select(), x, y);
            break;
        case 10:
            b.shift(r, vector_a_select(), direct(pick(0x001, 0x02F)));
            break;
        case 11:
            b.abs(r, x);
            break;
        case 12: {
            // the element's private index register, from a constant or from
            // a value of the element's own
            b.idx(other_index(own), direct(chance(2) ? base_j : base_i),
                  chance(2) ? direct(0) : block_operand(own));
            break;
        }
        default: {
            const csp::Operand wide =
                    csp::Operand::indexed(own, 2 * pick(0, 7));
            switch (pick(0, 3)) {
            case 0:
                b.mac_wide(wide, x, direct(0x0E0 + 2 * pick(0, 15)));
                break;
            case 1:
                b.macw_wide(wide, x, wide);
                break;
            case 2:
                b.interp_wide(wide, x, direct(0x0E0 + 2 * pick(0, 15)));
                break;
            default:
                b.add3_wide(wide, x, direct(0x0E0 + 2 * pick(0, 15)));
                break;
            }
            break;
        }
        }
    }

    // A vector loop on `own`, which must not be the index register of an
    // enclosing loop.
    void vector_loop(csp::ProgramBuilder &b,
                     std::optional<csp::IndexRegister> enclosing = {}) {
        const csp::IndexRegister own =
                enclosing ? other_index(*enclosing)
                          : (chance(2) ? csp::IndexRegister::i
                                       : csp::IndexRegister::j);
        const int counts[] = {count_base + 0, count_base + 1, count_base + 2,
                              count_base + 3, count_nine,     count_nine,
                              count_zero};
        const size_t at    = b.open_loop(own, direct(counts[pick(0, 6)]),
                                         direct(stride_base + 3), true);
        const int body     = pick(1, 6);
        for (int n = 0; n < body; ++n) {
            vector_instruction(b, own);
        }
        b.close_loop(at);
    }

    void loop(csp::ProgramBuilder &b, bool may_nest) {
        const bool on_j = chance(2);
        const size_t at = b.open_loop(on_j ? csp::IndexRegister::j
                                           : csp::IndexRegister::i,
                                      direct(count_base + pick(0, 3)),
                                      direct(stride_base + pick(0, 3)));
        const int body = pick(1, 5);
        for (int n = 0; n < body; ++n) {
            if (may_nest && chance(7)) {
                vector_loop(b, on_j ? csp::IndexRegister::j
                                    : csp::IndexRegister::i);
            } else if (may_nest && chance(5)) {
                // the inner loop steps the other index register
                const size_t inner = b.open_loop(
                        on_j ? csp::IndexRegister::i : csp::IndexRegister::j,
                        direct(count_base + pick(0, 2)),
                        direct(stride_base + pick(0, 3)));
                const int inner_body = pick(1, 3);
                for (int m = 0; m < inner_body; ++m) {
                    instruction(b, true);
                }
                b.close_loop(inner);
            } else {
                instruction(b, true);
            }
        }
        b.close_loop(at);
    }

    std::mt19937 random_;
};

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    // The seed: `+verilator+seed+N` as `make sim` passes it, or a plain
    // first number; a plain second number is how many random programs.
    uint32_t seed = 1;
    int programs  = 200;
    std::vector<std::string> numbers;
    for (int arg = 1; arg < argc; ++arg) {
        const std::string text      = argv[arg];
        const std::string seed_flag = "+verilator+seed+";
        if (text.rfind(seed_flag, 0) == 0) {
            seed = static_cast<uint32_t>(
                    std::strtoul(text.c_str() + seed_flag.size(), nullptr, 10));
        } else if (!text.empty() && text[0] != '+') {
            numbers.push_back(text);
        }
    }
    if (!numbers.empty()) {
        seed = static_cast<uint32_t>(
                std::strtoul(numbers[0].c_str(), nullptr, 10));
    }
    if (numbers.size() > 1) {
        programs = std::atoi(numbers[1].c_str());
    }
    std::printf("SIM_SEED=%u\n", seed);

    int failures = 0;

    // The manual's programs, with firmware writes to drive them. The
    // envelope runs as LOOP.i and as LOOP.vi, for voice counts below and
    // above the 7 elements that hide an instruction's wait.
    struct EnvelopeCase {
        const char *name;
        const char *program;
        int voices;
    };
    const EnvelopeCase envelope_cases[] = {
            {"envelope", envelope_program, 4},
            {"envelope vector", envelope_vector_program, 4},
            {"envelope vector of 1", envelope_vector_program, 1},
            {"envelope vector of 9", envelope_vector_program, 9},
            {"envelope vector of 32", envelope_vector_program, 32},
    };
    for (const EnvelopeCase &variant : envelope_cases) {
        std::string source           = variant.program;
        const std::string count_text = "=#4, =#16";
        source.replace(source.find(count_text), count_text.size(),
                       "=#" + std::to_string(variant.voices) + ", =#16");
        const csp::Program envelope      = csp::assemble(source);
        std::vector<FirmwareWrite> setup = constants_of(envelope);
        setup.push_back({0x060, 0x200}); // ENV_TABLE
        // Rows of the envelope table: target (wide: upper, lower), rate.
        const int table[][2] = {
                {0x200, 21299}, {0x201, 0}, {0x202, 1638}, // attack: 1.3, 0.1
                {0x204, 8192},  {0x205, 0}, {0x206, 819},  // decay: 0.5, 0.05
                {0x208, 0},     {0x209, 0}, {0x20a, 819}}; // release: 0, 0.05
        for (const auto &entry : table) {
            setup.push_back({entry[0], entry[1]});
        }
        for (int voice = 0; voice < variant.voices; ++voice) {
            const int stage =
                    voice < 4 ? (voice == 3 ? 8 : 0) : 4 * (voice % 3);
            const int gate     = voice < 4 ? (voice < 2 ? 16384 : 0)
                                           : (voice % 2 ? 16384 : 0);
            const int velocity = 8192 * (voice < 4 ? voice + 1 : voice % 5 + 1);
            setup.push_back({0x600 + 16 * voice + 2, stage});
            setup.push_back({0x600 + 16 * voice + 3, gate});
            setup.push_back({0x600 + 16 * voice + 4, velocity});
        }
        CoSim cosim(context);
        cosim.start(envelope.words, setup);
        int differences = 0;
        for (int pass = 0; pass < 60 && differences == 0; ++pass) {
            std::vector<FirmwareWrite> writes;
            if (pass == 30) {
                writes.push_back({0x600 + 3, 0}); // voice 0: gate off
            }
            differences =
                    cosim.pass(writes, std::string(variant.name) + " pass "
                                               + std::to_string(pass));
        }
        std::printf("%s: %s\n", variant.name, differences ? "FAIL" : "match");
        failures += differences != 0;
    }
    {
        const csp::Program lfo           = csp::assemble(lfo_program);
        std::vector<FirmwareWrite> setup = constants_of(lfo);
        setup.push_back({0x062, 1});      // RATE, wide: upper word
        setup.push_back({0x063, 0x1234}); //   lower word
        CoSim cosim(context);
        cosim.start(lfo.words, setup);
        int differences = 0;
        for (int pass = 0; pass < 20 && differences == 0; ++pass) {
            differences = cosim.pass({}, "lfo pass " + std::to_string(pass));
        }
        std::printf("lfo: %s\n", differences ? "FAIL" : "match");
        failures += differences != 0;
    }

    {
        const int differences = run_control_program(context);
        std::printf("control program: %s\n", differences ? "FAIL" : "match");
        failures += differences != 0;
    }

    // Random programs.
    int matched = 0;
    for (int n = 0; n < programs; ++n) {
        Generator generator(seed * 7919u + static_cast<uint32_t>(n));
        const std::vector<uint64_t> words = generator.program();
        CoSim cosim(context);
        const char *trace = std::getenv("CSP_TRACE_PROGRAM");
        cosim.trace(trace != nullptr && std::atoi(trace) == n);
        cosim.verbose(std::getenv("CSP_VERBOSE") != nullptr);
        cosim.start(words, generator.setup());
        int differences = 0;
        for (int pass = 0; pass < 4 && differences == 0; ++pass) {
            differences = cosim.pass(generator.writes_between_passes(),
                                     "program " + std::to_string(n) + " pass "
                                             + std::to_string(pass));
        }
        if (differences == 0) {
            ++matched;
        } else {
            std::printf("  program %d:\n", n);
            for (size_t at = 0; at < words.size(); ++at) {
                const csp::Instruction ins =
                        csp::Instruction::decode(words[at]);
                std::printf("    %3zu %-6s a=%d r=%03x x=%03x y=%03x\n", at,
                            std::string(csp::mnemonic(ins.op)).c_str(),
                            static_cast<int>(ins.a), ins.r, ins.x, ins.y);
            }
            ++failures;
            if (failures > 5) {
                break;
            }
        }
    }
    std::printf("random programs: %d of %d match (%d of %d passes ran into the "
                "pass limit)\n",
                matched, programs, CoSim::passes_at_limit, CoSim::passes_run);

    if (failures) {
        std::printf("%d FAILURE(S)\n", failures);
    } else {
        std::printf("ALL PASS\n");
    }
    return failures ? 1 : 0;
}
