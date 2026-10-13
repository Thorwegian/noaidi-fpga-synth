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

csp::Program assemble_file(const std::string &path,
                           const std::string &from = "",
                           const std::string &to   = "") {
    std::string source = read_file(path);
    if (!from.empty()) {
        const size_t at = source.find(from);
        if (at == std::string::npos) {
            std::printf("%s: no \"%s\"\n", path.c_str(), from.c_str());
            std::exit(2);
        }
        source.replace(at, from.size(), to);
    }
    csp::Program program = csp::assemble(source);
    bool failed          = false;
    for (const csp::Diagnostic &d : program.diagnostics) {
        std::printf("%s:%d: %s\n", path.c_str(), d.line, d.message.c_str());
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
constexpr int table_base     = 0x200;            // a table of 28 words a voice
constexpr int voice_base     = 0x600;            // a block of 16 words a voice

int table_of(int voice) {
    return table_base + 32 * voice;
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
    const csp::EnvelopeRate rate = csp::envelope_rate(coefficient);
    writes.push_back({row + 2, rate.rate});
    writes.push_back({row + 3, rate.shift});
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

// How far a level is from another, as the largest absolute difference (of
// full scale) and the largest ratio in dB where the level is above -60 dB.
struct Difference {
    double absolute   = 0;
    int absolute_pass = 0;
    double decibels   = 0;
    int decibels_pass = 0;

    void add(double level, double reference, int pass) {
        if (std::fabs(level - reference) > absolute) {
            absolute      = std::fabs(level - reference);
            absolute_pass = pass;
        }
        if (reference >= 0.001 && level > 0.0) {
            const double db = 20.0 * std::log10(level / reference);
            if (std::fabs(db) > std::fabs(decibels)) {
                decibels      = db;
                decibels_pass = pass;
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
    const csp::Program program = assemble_file(
            std::string(CSP_PROGRAMS_DIR) + "/envelope.s", "=#8, =#16",
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
            "  largest difference (of full scale) / largest ratio above -60 dB\n");
    std::printf("  voice   program vs ideal       unit vs ideal          "
                "program vs unit\n");
    int failures = 0;
    for (int envelope = 0; envelope < 2 * voices; ++envelope) {
        const Error &e = errors[envelope];
        auto cell      = [](const Difference &d) {
            char text[48];
            std::snprintf(text, sizeof text, "%.1e %+.3f dB", d.absolute,
                               d.decibels);
            return std::string(text);
        };
        // The bounds. The program stays within 0.1 dB of the exact RC curve
        // above -60 dB, and within 1 % of full scale of it everywhere (the
        // attack overshoots full scale by up to a step before it ends); and
        // within 0.1 dB of the old unit, plus the old unit's own distance
        // from the exact curve, which for slow rates is its truncation.
        const bool ok = std::fabs(e.program_vs_ideal.decibels) <= 0.1
                        && e.program_vs_ideal.absolute <= 0.01
                        && std::fabs(e.program_vs_unit.decibels)
                                   <= 0.1 + std::fabs(e.unit_vs_ideal.decibels);
        char name[16];
        std::snprintf(name, sizeof name, "%d%s", envelope / 2,
                      envelope % 2 ? " mod" : " amp");
        std::printf("  %-6s  %-22s %-22s %-22s %s\n", name,
                    cell(e.program_vs_ideal).c_str(),
                    cell(e.unit_vs_ideal).c_str(),
                    cell(e.program_vs_unit).c_str(), ok ? "ok" : "FAIL");
        failures += ok ? 0 : 1;
    }
    return failures;
}

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    int failures = bench_envelope(context);
    std::printf(failures ? "%d FAILURE(S)\n" : "ALL PASS\n", failures);
    return failures ? 1 : 0;
}
