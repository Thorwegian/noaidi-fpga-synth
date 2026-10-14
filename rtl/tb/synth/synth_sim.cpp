// synth_sim.cpp -- the system bench: the whole synthesizer, programmed over SPI
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The real top level (Verilated, tb_synth.sv) as the board has it, driven the
// way the firmware drives it: over SPI, with a CSP program loaded while the
// CSP is held, its constants and settings written through the write queue,
// and the partials' pointers set. What comes out is checked as a listener
// would hear it: the pitch from the zero crossings, the level, the release,
// the pan, and that a setting changed while a note sounds takes effect at once
// and stays (the sink area's two pages must agree).
//
// Exit status 0: all pass.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "Vtb_synth.h"
#include "assembler.hpp"
#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "svdpi.h"
#include "verilated.h"

#ifndef CSP_PROGRAMS_DIR
#define CSP_PROGRAMS_DIR "../tools/csp/programs"
#endif

extern "C" {
int synth_register(int address);
int synth_sink(int offset);
int synth_pointer(int partial, int position);
int synth_counters(int which);
int synth_queue_counters(int which);
}

namespace {

// ---- the clock, the SPI master and the audio tap ------------------------------------------

constexpr int sample_cycles = 768;     // one 96 kHz sample, in system clocks
constexpr int pass_cycles   = 1536;    // one CSP pass
constexpr int spi_half      = 4;       // system clocks per SCLK half period: 9.2 MHz

struct Sample {
    int left;      // what the listener hears
    int right;
    int mix_left;  // the pipeline's mix
    int mix_right;
};

// Verilator hands a 24-bit signed port over zero-extended.
int signed24(uint32_t bits) {
    return static_cast<int>(bits << 8) >> 8;
}

class Synth {
public:
    explicit Synth(VerilatedContext &context) : top_(&context) {
        svSetScope(svGetScopeFromName("TOP.tb_synth"));
        top_.sclk = 0;
        top_.cs   = 1;
        top_.mosi = 0;
        // A real falling edge of the reset, for the flip-flops that have only
        // an asynchronous one: Verilator does not see a level that starts low.
        top_.rst = 0;
        cycle();
        top_.rst = 1;
        for (int n = 0; n < 8; ++n) {
            cycle();
        }
        top_.rst = 0;
        cycle();
    }

    void cycle() {
        top_.sysclk = 0;
        top_.eval();
        top_.sysclk = 1;
        top_.eval();
        if (top_.sample_tick && !tick_seen_) {
            samples_.push_back({signed24(top_.out_left), signed24(top_.out_right),
                                signed24(top_.mix_left), signed24(top_.mix_right)});
        }
        tick_seen_ = top_.sample_tick;
        ++cycles_;
    }

    void run(int64_t cycles) {
        for (int64_t n = 0; n < cycles; ++n) {
            cycle();
        }
    }

    void run_passes(int passes) {
        run(int64_t{passes} * pass_cycles);
    }

    // One SPI frame: the bytes out, MSB first, SCLK mode 0.
    std::vector<uint8_t> frame(const std::vector<uint8_t> &out) {
        std::vector<uint8_t> in;
        top_.cs = 0;
        run(spi_half);
        for (uint8_t byte : out) {
            uint8_t got = 0;
            for (int bit = 7; bit >= 0; --bit) {
                top_.mosi = (byte >> bit) & 1;
                run(spi_half);
                got = static_cast<uint8_t>((got << 1) | top_.miso);
                top_.sclk = 1;
                run(spi_half);
                top_.sclk = 0;
            }
            in.push_back(got);
        }
        run(spi_half);
        top_.cs = 1;
        run(4 * spi_half);
        return in;
    }

    void write(uint16_t address, uint32_t value) {
        frame({0x40, static_cast<uint8_t>(address >> 8),
               static_cast<uint8_t>(address), static_cast<uint8_t>(value >> 24),
               static_cast<uint8_t>(value >> 16),
               static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)});
    }

    uint32_t read(uint16_t address) {
        const std::vector<uint8_t> in = frame(
                {0xC0, static_cast<uint8_t>(address >> 8),
                 static_cast<uint8_t>(address), 0, 0, 0, 0, 0, 0});
        return (uint32_t{in[5]} << 24) | (uint32_t{in[6]} << 16)
               | (uint32_t{in[7]} << 8) | in[8];
    }

    const std::vector<Sample> &samples() const {
        return samples_;
    }
    size_t mark() const {
        return samples_.size();
    }
    int64_t cycles() const {
        return cycles_;
    }
    uint32_t passes() const {
        return top_.passes;
    }

private:
    Vtb_synth top_;
    std::vector<Sample> samples_;
    bool tick_seen_ = false;
    int64_t cycles_ = 0;
};

// ---- the control plane, as the firmware speaks it ------------------------------------------------

constexpr uint16_t ctrl_address         = 0x0002;
constexpr uint16_t program_high_address = 0x0010;
constexpr uint16_t partial_base         = 0x2000;
constexpr uint16_t queue_base           = 0x6000;
constexpr uint16_t program_base         = 0x8000;
constexpr uint32_t ctrl_swap = 1, ctrl_hold = 2;

struct Write {
    int address;   // a register or a sink word (0x000–0xBFF)
    int32_t raw;
};

// The firmware's link: queued writes, committed by a swap, applied by the
// CSP's write window (48 a pass); the program loads while the CSP is held.
class Link {
public:
    explicit Link(Synth &synth) : synth_(synth) {}

    void hold() {
        synth_.write(ctrl_address, ctrl_hold);
    }
    void release() {
        synth_.write(ctrl_address, 0);
    }

    void load(const std::vector<uint64_t> &words) {
        for (size_t pc = 0; pc < words.size(); ++pc) {
            synth_.write(program_high_address,
                         static_cast<uint32_t>(words[pc] >> 32));
            synth_.write(static_cast<uint16_t>(program_base + pc),
                         static_cast<uint32_t>(words[pc]));
        }
    }

    // Queue the writes (the queue holds 512) and commit them. `held`: the
    // CSP is held, and a pass applies them all; running, 48 a pass.
    void commit(const std::vector<Write> &writes, bool held) {
        constexpr size_t chunk = 256;
        if (std::getenv("SYNTH_DEBUG")) {
            std::printf("  committing %zu writes\n", writes.size());
        }
        for (size_t done = 0; done < writes.size();) {
            const size_t end = std::min(writes.size(), done + chunk);
            for (; done < end; ++done) {
                synth_.write(static_cast<uint16_t>(queue_base
                                                   + writes[done].address),
                             static_cast<uint32_t>(writes[done].raw) & 0x3FFFF);
            }
            synth_.write(ctrl_address, ctrl_swap | (held ? ctrl_hold : 0));
            synth_.run_passes(held ? 2 : 6);
        }
    }

    // A partial's ten pointers: three to a word, the fourth word commits.
    void point(int partial, const int (&pointers)[10]) {
        const uint16_t base = static_cast<uint16_t>(partial_base + 64 * partial);
        for (int word = 0; word < 3; ++word) {
            synth_.write(base + word,
                         static_cast<uint32_t>(pointers[3 * word])
                                 | static_cast<uint32_t>(pointers[3 * word + 1]) << 10
                                 | static_cast<uint32_t>(pointers[3 * word + 2]) << 20);
        }
        synth_.write(base + 3, static_cast<uint32_t>(pointers[9]));
    }

private:
    Synth &synth_;
};

// ---- the control program ------------------------------------------------------------------------

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

int word_of(double value) {
    return static_cast<int>(std::lround(value * 16384.0));
}

void write_wide(std::vector<Write> &writes, int address, int64_t raw36) {
    writes.push_back({address, static_cast<int32_t>((raw36 >> 18) & 0x3FFFF)});
    writes.push_back({address + 1, static_cast<int32_t>(raw36 & 0x3FFFF)});
}

// ---- measuring what comes out -----------------------------------------------------------------------

struct Window {
    double rms;
    double peak;
    double frequency;   // from the rising zero crossings, Hz
};

Window measure(const std::vector<Sample> &samples, size_t first, size_t last,
               bool left) {
    double sum = 0, peak = 0;
    int crossings = 0;
    size_t first_crossing = 0, last_crossing = 0;
    double previous = 0;
    for (size_t n = first; n < last; ++n) {
        const double value = (left ? samples[n].left : samples[n].right)
                             / 8388608.0;
        sum += value * value;
        peak = std::max(peak, std::fabs(value));
        if (n > first && previous < 0 && value >= 0) {
            if (crossings == 0) {
                first_crossing = n;
            }
            last_crossing = n;
            ++crossings;
        }
        previous = value;
    }
    Window window{std::sqrt(sum / double(last - first)), peak, 0};
    if (crossings > 2) {
        window.frequency = 96000.0 * (crossings - 1)
                           / double(last_crossing - first_crossing);
    }
    return window;
}

int failures = 0;

void check(bool condition, const char *what) {
    std::printf("  %s: %s\n", condition ? "pass" : "FAIL", what);
    failures += !condition;
}

// ---- one voice on one channel -----------------------------------------------------------------------------

struct Layout {
    csp::Program program;
    int channels, channel_size, voices, voice_size, lfos, lfo_size, sinks, channel_sinks;
    int zero_sink;

    int symbol(const char *name) const {
        return program.symbols.at(name);
    }
};

Layout assemble_control_program() {
    Layout layout;
    layout.program = csp::assemble(control_program_text());
    for (const csp::Diagnostic &d : layout.program.diagnostics) {
        std::printf("control program, line %d: %s\n", d.line, d.message.c_str());
        if (d.error) {
            std::exit(1);
        }
    }
    layout.channels      = layout.symbol("CHANNELS");
    layout.channel_size  = layout.symbol("CHANNEL_SIZE");
    layout.voices        = layout.symbol("VOICES");
    layout.voice_size    = layout.symbol("VOICE_SIZE");
    layout.lfos          = layout.symbol("LFOS");
    layout.lfo_size      = layout.symbol("LFO_SIZE");
    layout.sinks         = layout.symbol("SINKS");
    layout.channel_sinks = layout.symbol("CHANNEL_SINKS");
    layout.zero_sink     = layout.symbol("ZERO_SINK");
    return layout;
}

// The sink words of a channel's block and a voice's, by name.
struct SinkMap {
    const Layout &layout;
    int voice_sink(int voice, const char *field) const {
        return layout.sinks + 8 * voice + layout.symbol(field);
    }
    int channel_sink(int channel, const char *field, int index = 0) const {
        return layout.channel_sinks + channel * layout.symbol("CHANNEL_SINK_SIZE")
               + layout.symbol(field) + index;
    }
};

// Voice `voice` on channel `channel`, `partials` unison partials at
// octaves `detune` apart: everything the firmware writes at setup.
struct Patch {
    double note        = 0.0;    // octaves from middle C
    double volume      = 1.0;
    double left        = 0.5;    // the channel's gain on each side
    double right       = 0.5;
    double cutoff_base = 3.0;    // octaves from middle C: wide open
    int waveform       = 3;      // sine
    int partials       = 1;
};

std::vector<Write> setup_writes(const Layout &layout, const Patch &patch) {
    std::vector<Write> writes;
    for (const csp::ConstantWrite &constant : layout.program.constants) {
        writes.push_back({constant.address, constant.raw});
    }
    // no LFOs running: both sets empty
    for (int half = 0; half < 2; ++half) {
        const int set = layout.symbol("LFO_SETS") + half * layout.symbol("SET_SIZE");
        writes.push_back({set + layout.symbol("BASE"),
                          layout.lfos + half * 16 * layout.lfo_size});
    }
    const int channel = layout.channels;
    auto table = [&](int row, int64_t target22, uint32_t coefficient) {
        write_wide(writes, channel + row, target22 << 10);
        write_wide(writes, channel + row + 2, csp::envelope_rate(coefficient));
    };
    for (int kind = 0; kind < 2; ++kind) {
        const int row = 16 * kind;
        table(row + 0, 0x533333, 40000);   // attack: a few ms
        table(row + 4, 0x200000, 12000);   // decay to half
        table(row + 8, 0, 8000);           // release: ~ 25 ms
    }
    auto field = [&](const char *name, int raw) {
        writes.push_back({channel + layout.symbol(name), raw});
    };
    field("LFO1", layout.lfos);
    field("LFO2", layout.lfos);
    field("SINK_BLOCK", layout.channel_sinks);
    field("DUTY_BASE_0", 0);
    field("DUTY_BASE_1", 0);
    field("RESONANCE_BASE", 0);
    field("CUTOFF_BASE", word_of(patch.cutoff_base));
    field("KEY_TRACK", word_of(0.0));
    field("VOLUME", word_of(patch.volume));
    // every voice: idle, in release, on the channel, with its own sinks (a
    // voice with no sink pointer would write over the registers)
    for (int voice = 0; voice < 32; ++voice) {
        const int base = layout.voices + voice * layout.voice_size;
        writes.push_back({base + layout.symbol("STAGE_A"), 8});
        writes.push_back({base + layout.symbol("STAGE_M"), 24});
        writes.push_back({base + layout.symbol("VELOCITY"), word_of(1.0)});
        writes.push_back({base + layout.symbol("CHANNEL"), channel});
        writes.push_back({base + layout.symbol("NOTE"), word_of(patch.note)});
        writes.push_back({base + layout.symbol("SINK"), layout.sinks + 8 * voice});
    }

    // the channel's own sink words: what only a MIDI message moves
    const SinkMap sinks{layout};
    for (int partial = 0; partial < patch.partials; ++partial) {
        writes.push_back({sinks.channel_sink(0, "DETUNE", partial), 0});
        writes.push_back({sinks.channel_sink(0, "CUTOFF_OFFSET", partial), 0});
        writes.push_back({sinks.channel_sink(0, "GAIN_LEFT", partial), word_of(patch.left)});
        writes.push_back({sinks.channel_sink(0, "GAIN_RIGHT", partial), word_of(patch.right)});
    }
    writes.push_back({sinks.channel_sink(0, "MODE_0"), patch.waveform});
    writes.push_back({layout.symbol("CHANNELS_IN_USE"), 1});
    return writes;
}

// The ten pointers of a voice's partial, as the firmware sets them.
void point_partial(Link &link, const Layout &layout, int partial, int voice,
                   int channel, int unison, int oscillator) {
    const SinkMap sinks{layout};
    auto index = [&](int address) { return address - csp::sink_base; };
    const int pointers[10] = {
        index(sinks.voice_sink(voice, "SINK_PITCH")),
        index(sinks.channel_sink(channel, "DETUNE", unison)),
        index(sinks.voice_sink(voice, "SINK_CUTOFF")),
        index(sinks.channel_sink(channel, "CUTOFF_OFFSET", unison)),
        index(sinks.voice_sink(voice, "SINK_GAIN")),
        index(sinks.channel_sink(channel, "GAIN_LEFT", unison)),
        index(sinks.channel_sink(channel, "GAIN_RIGHT", unison)),
        index(sinks.channel_sink(channel, oscillator ? "DUTY_1" : "DUTY_0")),
        index(sinks.channel_sink(channel, "RESONANCE")),
        index(sinks.channel_sink(channel, oscillator ? "MODE_1" : "MODE_0")),
    };
    link.point(partial, pointers);
}

// Bring the synthesizer up the way the firmware does: hold the CSP, load the
// program, write the constants and settings, point the partials, release.
void bring_up(Synth &synth, Link &link, const Layout &layout, const Patch &patch) {
    link.hold();
    link.load(layout.program.words);
    link.commit(setup_writes(layout, patch), true);
    for (int partial = 0; partial < patch.partials; ++partial) {
        point_partial(link, layout, partial, 0, 0, partial, 0);
    }
    link.release();
    synth.run_passes(4);
}

void strike(Synth &synth, Link &link, const Layout &layout, bool on) {
    std::vector<Write> writes;
    const int voice = layout.voices;
    if (on) {
        write_wide(writes, voice + layout.symbol("LEVEL_A"), 0);
        write_wide(writes, voice + layout.symbol("LEVEL_M"), 0);
    }
    writes.push_back({voice + layout.symbol("GATE"), on ? 16384 : 0});
    link.commit(writes, false);
}

// ---- the cases ---------------------------------------------------------------------------------------------------------

void case_tone(VerilatedContext &context, const Layout &layout) {
    std::printf("a note: pitch, level, pan, release, and a setting changed live\n");
    Synth synth(context);
    Link link(synth);
    Patch patch;
    patch.left  = 0.25;
    patch.right = 0.0;     // hard left
    bring_up(synth, link, layout, patch);

    check(synth.read(ctrl_address) == 0, "CTRL reads back what was written (released)");
    const size_t silent_from = synth.mark();
    synth.run(4 * pass_cycles);
    const Window silent = measure(synth.samples(), silent_from, synth.mark(), true);
    check(silent.peak < 1e-4, "silent before a note");

    strike(synth, link, layout, true);
    synth.run(int64_t{40} * sample_cycles * 96);    // 40 ms of attack and decay
    if (std::getenv("SYNTH_DEBUG")) {
        const int voice = layout.voices;
        std::printf("  voice: gate %d level_a %d stage_a %d note %d channel %d sink %d\n",
                    synth_register(voice + layout.symbol("GATE")),
                    synth_register(voice + layout.symbol("LEVEL_A")),
                    synth_register(voice + layout.symbol("STAGE_A")),
                    synth_register(voice + layout.symbol("NOTE")),
                    synth_register(voice + layout.symbol("CHANNEL")),
                    synth_register(voice + layout.symbol("SINK")));
        std::printf("  channel: cutoff_base %d volume %d ch_pitch %d ch_cutoff %d\n",
                    synth_register(layout.channels + layout.symbol("CUTOFF_BASE")),
                    synth_register(layout.channels + layout.symbol("VOLUME")),
                    synth_register(layout.channels + layout.symbol("CH_PITCH")),
                    synth_register(layout.channels + layout.symbol("CH_CUTOFF")));
        std::printf("  voice: out_a %d d %d u_m %d\n",
                    synth_register(voice + layout.symbol("OUT_A")),
                    synth_register(voice + layout.symbol("D")),
                    synth_register(voice + layout.symbol("U_M")));
        std::printf("  queue: %d written, %d while full, %d popped\n", synth_queue_counters(0),
                    synth_queue_counters(1), synth_queue_counters(2));
        for (int v = 0; v < 32; ++v) {
            const int base = layout.voices + v * layout.voice_size;
            const int sink = synth_register(base + layout.symbol("SINK"));
            if (sink != layout.sinks + 8 * v) {
                std::printf("  voice %d: SINK %d (want %d), CHANNEL %d, STAGE_A %d NOTE %d\n", v, sink,
                            layout.sinks + 8 * v, synth_register(base + layout.symbol("CHANNEL")),
                            synth_register(base + layout.symbol("STAGE_A")), synth_register(base + layout.symbol("NOTE")));
            }
        }
        for (const csp::ConstantWrite &c : layout.program.constants) {
            std::printf("  constant at %d = %d, register holds %d\n", c.address, c.raw, synth_register(c.address));
        }
        std::printf("  gain sinks: %d %d\n", synth_sink(0x110), synth_sink(0x118));
        std::printf("  csp sink writes %d, firmware sink writes %d, last csp sink address %d, flips %d\n",
                    synth_counters(0), synth_counters(1), synth_counters(2), synth_counters(3));
        std::printf("  last csp sink data %d, active page %d\n", synth_counters(4), synth_counters(5));
        std::printf("  voice sinks: pitch %d cutoff %d gain %d\n", synth_sink(0), synth_sink(1), synth_sink(2));
        std::printf("  pointers:");
        for (int k = 0; k < 10; ++k) std::printf(" %d", synth_pointer(0, k));
        std::printf("\n  channel sinks:");
        for (int k = 0; k < 12; ++k) std::printf(" %d", synth_sink(0x100 + k));
        std::printf("\n  passes %u\n", synth.passes());
    }
    const size_t from = synth.mark();
    synth.run(int64_t{50} * sample_cycles * 96);    // 50 ms to measure
    const Window left  = measure(synth.samples(), from, synth.mark(), true);
    const Window right = measure(synth.samples(), from, synth.mark(), false);
    const double c4 = 261.6256;
    std::printf("  left: %.2f Hz, peak %.4f, rms %.4f; right: peak %.6f\n",
                left.frequency, left.peak, left.rms, right.peak);
    check(std::fabs(left.frequency / c4 - 1.0) < 0.01, "middle C: 261.6 Hz within 1 %");
    check(left.peak > 0.02, "audible");
    check(right.peak < left.peak * 0.01, "hard left: the right side is silent");

    // a gain written while the note sounds: both pages must take it
    {
        std::vector<Write> writes;
        const SinkMap sinks{layout};
        writes.push_back({sinks.channel_sink(0, "GAIN_LEFT", 0), word_of(0.125)});
        link.commit(writes, false);
        synth.run(int64_t{5} * sample_cycles * 96);
        const size_t during = synth.mark();
        synth.run(int64_t{30} * sample_cycles * 96);
        const Window half = measure(synth.samples(), during, synth.mark(), true);
        std::printf("  after halving the gain: peak %.4f (was %.4f)\n", half.peak, left.peak);
        check(std::fabs(half.peak / left.peak - 0.5) < 0.08,
              "halving the channel's gain halves the level, and keeps it halved");
    }

    // release
    strike(synth, link, layout, false);
    synth.run(int64_t{300} * sample_cycles * 96);       // 300 ms
    const size_t tail_from = synth.mark();
    synth.run(int64_t{20} * sample_cycles * 96);
    const Window tail = measure(synth.samples(), tail_from, synth.mark(), true);
    std::printf("  after the release: peak %.6f\n", tail.peak);
    check(tail.peak < left.peak * 0.02, "released: the note has died away");
}

void case_pitch(VerilatedContext &context, const Layout &layout) {
    std::printf("pitch: an octave up is twice the frequency, a fifth is 3/2\n");
    for (const double note : {0.0, 0.1, 0.25, 0.5, 1.0, 7.0 / 12.0}) {
        Synth synth(context);
        Link link(synth);
        Patch patch;
        patch.note  = note;
        patch.left  = 0.25;    // under the limiter's threshold: a sine stays a sine
        patch.right = 0.0;
        patch.cutoff_base = 5.0;    // far above the notes: the filter stays out of it
        bring_up(synth, link, layout, patch);
        strike(synth, link, layout, true);
        synth.run(int64_t{40} * sample_cycles * 96);
        const size_t from = synth.mark();
        synth.run(int64_t{50} * sample_cycles * 96);
        const Window left = measure(synth.samples(), from, synth.mark(), true);
        const double want = 261.6256 * std::pow(2.0, note);
        std::printf("  %.3f octaves: %.2f Hz (want %.2f), peak %.4f\n", note, left.frequency, want, left.peak);
        if (std::getenv("SYNTH_DEBUG")) {
            double mix_peak = 0;
            for (size_t n = from; n < synth.mark(); ++n) {
                mix_peak = std::max(mix_peak, std::fabs(synth.samples()[n].mix_left / 8388608.0));
            }
            std::printf("  mix peak %.4f; partial 5 points at:", mix_peak);
            for (int k = 0; k < 10; ++k) std::printf(" %d", synth_pointer(5, k));
            std::printf("; sink[1023] = %d\n", synth_sink(1023));
            std::printf("  voice sinks: pitch %d cutoff %d gain %d; channel: detune %d gain left %d right %d mode %d\n",
                        synth_sink(0), synth_sink(1), synth_sink(2), synth_sink(0x100), synth_sink(0x110),
                        synth_sink(0x118), synth_sink(0x122));
        }
        if (const char *path = std::getenv("SYNTH_DUMP")) {
            std::ofstream out(std::string(path) + std::to_string(int(note * 1000)) + ".txt");
            for (size_t n = from; n < synth.mark(); ++n) out << synth.samples()[n].left << "\n";
        }
        check(std::fabs(left.frequency / want - 1.0) < 0.01, "within 1 %");
    }
}

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    const Layout layout = assemble_control_program();
    std::printf("control program: %zu instructions\n", layout.program.words.size());
    case_tone(context, layout);
    case_pitch(context, layout);
    std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
    return failures == 0 ? 0 : 1;
}
