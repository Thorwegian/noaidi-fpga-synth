// csp_bench.cpp — the CSP's programs against the units they replace
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Each bench runs a program from tools/csp/programs on the Verilated CSP
// (tb_csp_cosim.sv) next to the fixed-function unit it replaces
// (rtl/dsp), both driven by the same gates and settings, and compares
// their outputs once per 48 kHz pass. The error bounds are set out in the
// bench. docs/csp_isa.md section 12 describes them.
//
//   make sim-csp-bench            (rtl/Makefile)
//   obj_dir/csp_bench/sim [programs directory]

#include <algorithm>
#include <cinttypes>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "Vtb_csp_cosim.h"
#include "Vtb_csp_cosim__Dpi.h"
#include "assembler.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "csp_rtl.hpp"
#include "processor.hpp"
#include "svdpi.h"
#include "verilated.h"

#ifndef CSP_PROGRAMS_DIR
#define CSP_PROGRAMS_DIR "../tools/csp/programs"
#endif

namespace {

struct FirmwareWrite {
    int address;
    int32_t raw;
};

std::string read_file(const std::string &path) {
    std::ifstream file(path);
    if (!file) {
        std::printf("cannot read %s\n", path.c_str());
        std::exit(2);
    }
    std::stringstream text;
    text << file.rdbuf();
    return text.str();
}

// The program joined from files in tools/csp/programs, in order, with one
// replacement in the text if asked.
csp::Program assemble_files(const std::vector<std::string> &names,
                            const std::string &from = "",
                            const std::string &to   = "") {
    std::string source;
    for (const std::string &name : names) {
        source += read_file(std::string(CSP_PROGRAMS_DIR) + "/" + name) + "\n";
    }
    if (!from.empty()) {
        const size_t at = source.find(from);
        if (at == std::string::npos) {
            std::printf("no \"%s\" in the program\n", from.c_str());
            std::exit(2);
        }
        source.replace(at, from.size(), to);
    }
    csp::Program program = csp::assemble(source);
    bool failed          = false;
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::printf("program line %d: %s\n", d.line, d.message.c_str());
        failed |= d.error;
    }
    if (failed) {
        std::exit(2);
    }
    return program;
}

// A wide register pair's two words, as firmware writes.
void write_wide(std::vector<FirmwareWrite> &writes, int address,
                int64_t raw36) {
    writes.push_back({address, static_cast<int32_t>((raw36 >> 18) & 0x3FFFF)});
    writes.push_back({address + 1, static_cast<int32_t>(raw36 & 0x3FFFF)});
}

int64_t read_wide(const Rtl &rtl, int address) {
    const int64_t upper = rtl.reg(address);
    const int64_t lower = rtl.reg(address + 1) & 0x3FFFF;
    return (upper << 18) | lower;
}

// ---- the envelope ---------------------------------------------------------------------------
//
// tools/csp/programs/envelope.s, in 8 voices of two envelopes (amp and
// mod), against adsr.sv: one ADSR per envelope, stepped twice a pass. The
// envelopes have rates from the fastest adsr.sv takes to ones that barely
// move, and the voices play two notes each, the second struck while the
// first is still releasing.

struct Setting {
    uint32_t attack, decay, release; // adsr.sv's coefficients
    uint32_t sustain;                // 10 bits
};

constexpr int voices = 8;

const Setting settings[voices] = {
        {262143, 262143, 262143, 1023}, {60000, 30000, 40000, 600},
        {20000, 8000, 10000, 800},      {6000, 2000, 3000, 300},
        {2000, 700, 1200, 900},         {3000, 100, 60, 700},
        {800, 250, 400, 500},           {40, 40, 40, 100},
};

constexpr int64_t full_level = int64_t{1} << 22; // UQ4.22
constexpr int table_base     = 0x200; // the channels: voice v has channel v
constexpr int voice_base     = 0x600; // a block of 16 words a voice

int table_of(int voice) {
    return table_base + 64 * voice;
}
int block_of(int voice) {
    return voice_base + 16 * voice;
}

uint32_t rate_ad_of(const Setting &s) {
    return s.attack | ((s.decay & 0x3FFF) << 18);
}
uint32_t rate_dsr_of(const Setting &s) {
    return (s.decay >> 14) | (s.release << 4) | (s.sustain << 22);
}

void segment(std::vector<FirmwareWrite> &writes, int row, int64_t target22,
             uint32_t coefficient) {
    write_wide(writes, row, target22 << 10); // UQ4.22 → Q4.32
    write_wide(writes, row + 2, csp::envelope_rate(coefficient));
}

// adsr.sv's state machine in double precision: the same stages, targets and
// transitions, with no rounding. What both the old unit and the program
// approximate.
class IdealEnvelope {
public:
    explicit IdealEnvelope(const Setting &setting) : setting_(setting) {}

    void step(bool gate) {
        enum { idle, attack, decay, release };
        const int selected = !gate ? release
                                   : (stage_ == attack  ? attack
                                      : stage_ == decay ? decay
                                                        : attack);
        if (gate && stage_ == release) {
            level_ = 0.0; // a new note starts from nothing
        }
        const double k = (!gate                ? setting_.release
                          : selected == attack ? setting_.attack
                                               : setting_.decay)
                         / 16777216.0;
        const double target = !gate                ? 0.0
                              : selected == attack ? 0x533333 / 4194304.0
                                                   : setting_.sustain / 1024.0;
        level_ += (target - level_) * k;
        if (!gate) {
            stage_ = level_ == 0.0 ? idle : release;
        } else if (selected == attack && level_ >= 1.0) {
            stage_ = decay;
            level_ = 1.0;
        } else {
            stage_ = selected;
        }
    }
    double level() const {
        return level_;
    }

private:
    Setting setting_;
    int stage_    = 0;
    double level_ = 0.0;
};

// How far a level is from another: the largest absolute difference (of full
// scale), and the largest ratio in dB where the level is above -40 dB and
// above -60 dB.
struct Difference {
    double absolute      = 0;
    int absolute_pass    = 0;
    double decibels      = 0; // above -40 dB
    int decibels_pass    = 0;
    double decibels_60   = 0; // above -60 dB
    int decibels_60_pass = 0;

    void add(double level, double reference, int pass) {
        if (std::fabs(level - reference) > absolute) {
            absolute      = std::fabs(level - reference);
            absolute_pass = pass;
        }
        if (reference >= 0.001 && level > 0.0) {
            const double db = 20.0 * std::log10(level / reference);
            if (reference >= 0.01 && std::fabs(db) > std::fabs(decibels)) {
                decibels      = db;
                decibels_pass = pass;
            }
            if (std::fabs(db) > std::fabs(decibels_60)) {
                decibels_60      = db;
                decibels_60_pass = pass;
            }
        }
    }
};

struct Error {
    Difference program_vs_ideal;
    Difference unit_vs_ideal;
    Difference program_vs_unit;
};

// A voice's two envelopes: the amp envelope takes settings[voice], the mod
// envelope the settings of another voice.
const Setting &setting_of(int voice, int kind) {
    return settings[kind == 0 ? voice : (voice + 3) % voices];
}

// The fields of a voice block (envelope.s) for envelope `kind`.
int level_of(int voice, int kind) {
    return block_of(voice) + (kind == 0 ? 0 : 8);
}
int stage_of(int voice, int kind) {
    return block_of(voice) + (kind == 0 ? 2 : 10);
}

int bench_envelope(VerilatedContext &context) {
    // CSP_BENCH_TRACE=voice,kind,from,to prints an envelope's levels pass by pass
    int trace_voice = -1, trace_kind = 0, trace_from = 0, trace_to = 0;
    if (const char *trace = std::getenv("CSP_BENCH_TRACE")) {
        std::sscanf(trace, "%d,%d,%d,%d", &trace_voice, &trace_kind,
                    &trace_from, &trace_to);
    }
    const csp::Program program =
            assemble_files({"map.s", "envelope.s"}, "=#32, =#16",
                           "=#" + std::to_string(voices) + ", =#16");
    Rtl rtl(context);

    std::vector<FirmwareWrite> setup;
    for (const csp::ConstantWrite &constant : program.constants) {
        setup.push_back({constant.address, constant.raw});
    }
    for (int voice = 0; voice < voices; ++voice) {
        for (int kind = 0; kind < 2; ++kind) {
            const Setting &s = setting_of(voice, kind);
            const int table  = table_of(voice) + 16 * kind;
            segment(setup, table + 0, 0x533333, s.attack); // 1.3
            segment(setup, table + 4, int64_t{s.sustain} << 12,
                    s.decay); // sustain
            segment(setup, table + 8, 0, s.release);
            setup.push_back(
                    {stage_of(voice, kind), kind == 0 ? 8 : 24}); // release
            rtl.ref_set(2 * voice + kind, false, rate_ad_of(s), rate_dsr_of(s));
        }
        setup.push_back({block_of(voice) + 4, 16384}); // velocity
        setup.push_back({block_of(voice) + 5, table_of(voice)});
    }
    rtl.hold(true);
    rtl.load(program.words);
    for (const FirmwareWrite &write : setup) {
        rtl.write(write.address, write.raw);
    }
    rtl.swap();
    rtl.pass();
    rtl.hold(false);

    // Gates: voice v is struck at pass on1[v], released at off1[v], struck
    // again while releasing at on2[v], released at off2[v].
    auto on1 = [](int v) {
        return 60 + 37 * v;
    };
    auto off1 = [](int v) {
        return 6000 + 111 * v;
    };
    auto on2 = [](int v) {
        return 7500 + 53 * v;
    };
    auto off2 = [](int v) {
        return 10500 + 17 * v;
    };
    constexpr int passes = 13000;

    // Firmware writes land in the window after the next pass; the
    // references see the gate in the pass after that.
    std::vector<IdealEnvelope> ideal;
    for (int envelope = 0; envelope < 2 * voices; ++envelope) {
        ideal.emplace_back(setting_of(envelope / 2, envelope % 2));
    }
    std::vector<bool> ideal_gate(voices, false);
    std::vector<bool> forced(voices, false);
    std::vector<int> next_reference_gate(voices, -1); // -1: no change
    std::vector<bool> pending_gate(voices, false);
    std::vector<Error> errors(2 * voices);
    int releases_checked    = 0;
    int releases_unfinished = 0;
    for (int pass = 1; pass <= passes; ++pass) {
        // the references see what the firmware wrote in the previous pass
        for (int voice = 0; voice < voices; ++voice) {
            if (next_reference_gate[voice] >= 0) {
                for (int kind = 0; kind < 2; ++kind) {
                    const Setting &s = setting_of(voice, kind);
                    rtl.ref_set(2 * voice + kind,
                                next_reference_gate[voice] != 0, rate_ad_of(s),
                                rate_dsr_of(s));
                }
                ideal_gate[voice]          = next_reference_gate[voice] != 0;
                next_reference_gate[voice] = -1;
            }
        }
        std::vector<FirmwareWrite> writes;
        std::fill(forced.begin(), forced.end(), false);
        for (int voice = 0; voice < voices; ++voice) {
            bool gate = pending_gate[voice];
            if (pass == on1(voice) || pass == on2(voice)) {
                gate = true;
                // a new note starts from nothing
                write_wide(writes, level_of(voice, 0), 0);
                write_wide(writes, level_of(voice, 1), 0);
                forced[voice] = true;
            } else if (pass == off1(voice) || pass == off2(voice)) {
                gate = false;
            } else {
                continue;
            }
            next_reference_gate[voice] = gate ? 1 : 0;
            pending_gate[voice]        = gate;
            writes.push_back({block_of(voice) + 3, gate ? 16384 : 0});
        }
        for (const FirmwareWrite &write : writes) {
            rtl.write(write.address, write.raw);
        }
        if (!writes.empty()) {
            rtl.swap();
        }
        rtl.pass();

        for (int envelope = 0; envelope < 2 * voices; ++envelope) {
            const int voice = envelope / 2;
            const int kind  = envelope % 2;
            const double unit =
                    static_cast<double>(rtl.ref_state(envelope) & 0x3FFFFFF)
                    / full_level;
            const double program_level =
                    static_cast<double>(read_wide(rtl, level_of(voice, kind)))
                    / static_cast<double>(int64_t{1} << 32);
            for (int sample = 0; sample < 2; ++sample) {
                ideal[envelope].step(ideal_gate[voice]);
            }
            const double exact = ideal[envelope].level();
            if (trace_voice == voice && trace_kind == kind && pass >= trace_from
                && pass <= trace_to) {
                std::printf(
                        "  pass %d voice %d envelope %d: ideal %.6f unit %.6f "
                        "program %.6f stage %d\n",
                        pass, voice, kind, exact, unit, program_level,
                        rtl.reg(stage_of(voice, kind)));
            }
            // A release must finish: a voice whose exact level has reached 0
            // before it is struck again must have its output at exactly 0.
            if (kind == 0 && pass == on2(voice) - 1 && exact < 1e-6) {
                ++releases_checked;
                releases_unfinished += rtl.reg(block_of(voice) + 11) != 0;
            }
            if (forced[voice]) {
                continue; // the firmware just set the level
            }
            errors[envelope].program_vs_ideal.add(program_level, exact, pass);
            errors[envelope].unit_vs_ideal.add(unit, exact, pass);
            errors[envelope].program_vs_unit.add(program_level, unit, pass);
        }
    }

    std::printf("envelope: %d voices of two, %d passes (%.2f s)\n", voices,
                passes, passes / 48000.0);
    std::printf(
            "  largest difference (of full scale), largest ratio above -40 dB, "
            "above -60 dB\n");
    std::printf("  voice   program vs ideal                 unit vs ideal"
                "                    program vs unit\n");
    int failures = 0;
    for (int envelope = 0; envelope < 2 * voices; ++envelope) {
        const Error &e = errors[envelope];
        auto cell      = [](const Difference &d) {
            char text[64];
            std::snprintf(text, sizeof text, "%.0e %+.3f %+.3f dB", d.absolute,
                               d.decibels, d.decibels_60);
            return std::string(text);
        };
        // The bounds. The program stays within 0.1 dB of the exact RC curve
        // above -40 dB and 0.5 dB above -60 dB (it takes the distance as a
        // word, so it settles half a word's step, 3e-5, above the target:
        // 3 % of a -60 dB level), and within 1 % of full scale of it
        // everywhere (the attack overshoots full scale by up to a step
        // before it ends); and within the same of the old unit, plus the
        // old unit's own distance from the exact curve, which for slow
        // rates is its truncation.
        const bool ok =
                std::fabs(e.program_vs_ideal.decibels) <= 0.1
                && std::fabs(e.program_vs_ideal.decibels_60) <= 0.5
                && e.program_vs_ideal.absolute <= 0.01
                && std::fabs(e.program_vs_unit.decibels)
                           <= 0.1 + std::fabs(e.unit_vs_ideal.decibels)
                && std::fabs(e.program_vs_unit.decibels_60)
                           <= 0.5 + std::fabs(e.unit_vs_ideal.decibels_60);
        char name[16];
        std::snprintf(name, sizeof name, "%d%s", envelope / 2,
                      envelope % 2 ? " mod" : " amp");
        std::printf("  %-6s  %-30s %-30s %-30s %s\n", name,
                    cell(e.program_vs_ideal).c_str(),
                    cell(e.unit_vs_ideal).c_str(),
                    cell(e.program_vs_unit).c_str(), ok ? "ok" : "FAIL");
        failures += ok ? 0 : 1;
    }
    std::printf("  releases that must have finished (exact level 0 by the next "
                "note): %d checked, %d with an output not 0\n",
                releases_checked, releases_unfinished);
    failures += releases_unfinished + (releases_checked == 0 ? 1 : 0);
    return failures;
}

// ---- the LFOs ---------------------------------------------------------------------------------
//
// tools/csp/programs/lfo.s, in 8 LFOs (two of each shape, sorted), against
// osc_core: the same phase goes to both, and the program's output must be
// osc_core's wave at that phase, scaled to ±depth (osc_core's full scale is
// ±0.5). The rates run from a cycle in a few thousand passes to several
// cycles a pass; the depths from a tenth to two. The program updates an LFO
// every other pass, so each pass compares the phase it has and its output.

struct LfoSetting {
    int shape;          // 0 saw, 1 square, 2 triangle, 3 sine
    uint32_t increment; // the old unit's 16-bit phase increment
    double depth;
};

constexpr int lfos = 8;

const LfoSetting lfo_settings[lfos] = {
        {0, 2000, 1.0}, {0, 40, 0.5},   {1, 3000, 1.0}, {1, 100, 0.25},
        {2, 1500, 2.0}, {2, 7000, 0.1}, {3, 500, 1.0},  {3, 10000, 2.0},
};

constexpr int lfo_base = 0x080; // the pool (map.s); the first half's records

int lfo_block(int lfo) {
    return lfo_base + 12 * lfo;
}

int to_word(double value) {
    return static_cast<int>(std::lround(value * 16384.0));
}

int bench_lfo(VerilatedContext &context) {
    const csp::Program program = assemble_files({"map.s", "lfo.s"});
    Rtl rtl(context);

    std::vector<FirmwareWrite> setup;
    for (const csp::ConstantWrite &constant : program.constants) {
        setup.push_back({constant.address, constant.raw});
    }
    int counts[4] = {0, 0, 0, 0};
    for (int lfo = 0; lfo < lfos; ++lfo) {
        const LfoSetting &s = lfo_settings[lfo];
        ++counts[s.shape];
        const int block = lfo_block(lfo);
        write_wide(setup, block + 2, csp::lfo_rate(s.increment, 2));
        setup.push_back({block + 4, to_word(s.depth)});
        setup.push_back({block + 5, to_word(-s.depth)});
        setup.push_back({block + 6, s.shape == 0   ? to_word(s.depth / 8)
                                    : s.shape == 2 ? to_word(s.depth / 4)
                                                   : 0});
    }
    // the LFOs are in the pool's first half; one pass in two updates them, the
    // other pass runs the second half, which holds none
    const int sets = program.symbols.at("LFO_SETS");
    for (int half = 0; half < 2; ++half) {
        const int set = sets + 8 * half;
        setup.push_back(
                {set + program.symbols.at("BASE"), lfo_base + half * 16 * 12});
        for (int shape = 0; shape < 4; ++shape) {
            setup.push_back({set + program.symbols.at("N_SAW") + shape,
                             half == 0 ? counts[shape] : 0});
        }
    }
    rtl.hold(true);
    rtl.load(program.words);
    for (const FirmwareWrite &write : setup) {
        rtl.write(write.address, write.raw);
    }
    rtl.swap();
    rtl.pass();
    rtl.hold(false);

    struct Worst {
        double program_vs_unit  = 0;
        double program_vs_exact = 0;
        double unit_vs_exact    = 0;
        int pass                = 0;
    };
    std::vector<Worst> worst(lfos);
    constexpr int passes = 4000;
    constexpr double pi  = 3.14159265358979323846;
    for (int pass = 1; pass <= passes; ++pass) {
        rtl.pass();
        for (int lfo = 0; lfo < lfos; ++lfo) {
            const LfoSetting &s = lfo_settings[lfo];
            const int64_t phase = read_wide(rtl, lfo_block(lfo));
            // the 36-bit phase's top 24 bits are osc_core's phase
            const int phase24        = static_cast<int>(phase >> 12);
            const double program_out = rtl.reg(lfo_block(lfo) + 7) / 16384.0;
            // osc_core is ±0.5 at full scale: Q2.16 of 32768
            const double unit =
                    2.0 * s.depth * rtl.osc_wave(s.shape, phase24) / 65536.0;
            const double x = static_cast<double>(phase24) / (1 << 24); // cycles
            double exact;
            switch (s.shape) {
            case 0:
                exact = 2.0 * x;
                break;
            case 1:
                exact = x < 0 ? 1.0 : -1.0;
                break;
            case 2:
                exact = 4.0 * std::fabs(x) - 1.0;
                break;
            default:
                exact = std::sin(2.0 * pi * x);
                break;
            }
            exact *= s.depth;
            Worst &w            = worst[lfo];
            const double d_unit = std::fabs(program_out - unit);
            if (d_unit > w.program_vs_unit) {
                w.program_vs_unit = d_unit;
                w.pass            = pass;
            }
            w.program_vs_exact = std::max(w.program_vs_exact,
                                          std::fabs(program_out - exact));
            w.unit_vs_exact =
                    std::max(w.unit_vs_exact, std::fabs(unit - exact));
        }
    }

    static const char *const shapes[4] = {"saw", "square", "triangle", "sine"};
    std::printf("lfo: %d LFOs, %d passes (%.2f s); differences in units of the "
                "depth\n",
                lfos, passes, passes / 48000.0);
    std::printf("  lfo  shape     increment depth |  program vs osc_core  "
                "program vs exact  osc_core vs exact\n");
    int failures = 0;
    for (int lfo = 0; lfo < lfos; ++lfo) {
        const LfoSetting &s = lfo_settings[lfo];
        const Worst &w      = worst[lfo];
        // The bounds. The saw, square and triangle are exact up to the
        // words' rounding (2^-14) and the rounding of the gain constant
        // (depth ÷ 8 or ÷ 4 in a word: half a raw unit of it, relative). The
        // sine's polynomial is good to 0.15 % of the depth, and osc_core's
        // table is itself 0.31 % off the exact sine, which the program is
        // allowed on top of.
        const double word     = 1.0 / 16384.0;
        const double gain_raw = s.shape == 0   ? s.depth / 8 * 16384
                                : s.shape == 2 ? s.depth / 4 * 16384
                                               : 0;
        const double gain_error =
                gain_raw > 0 ? 2.0 * s.depth * 0.5 / gain_raw : 0;
        const double bound =
                (s.shape == 3 ? 0.0015 : 0.0) * s.depth + gain_error + 4 * word;
        const double bound_unit =
                (s.shape == 3 ? 0.0050 : 0.0) * s.depth + gain_error + 4 * word;
        const bool ok =
                w.program_vs_exact <= bound && w.program_vs_unit <= bound_unit;
        std::printf("  %3d  %-8s %9u %5.2f | %.2e (@%d)       %.2e          "
                    "%.2e  %s\n",
                    lfo, shapes[s.shape], s.increment, s.depth,
                    w.program_vs_unit / s.depth, w.pass,
                    w.program_vs_exact / s.depth, w.unit_vs_exact / s.depth,
                    ok ? "ok" : "FAIL");
        failures += ok ? 0 : 1;
    }
    return failures;
}

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    int failures = bench_envelope(context);
    failures += bench_lfo(context);
    std::printf(failures ? "%d FAILURE(S)\n" : "ALL PASS\n", failures);
    return failures ? 1 : 0;
}
