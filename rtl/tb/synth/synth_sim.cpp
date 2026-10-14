// synth_sim.cpp -- the system bench: the whole synthesizer, programmed over SPI
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The real top level (Verilated, tb_synth.sv) as the board has it, driven the
// way the firmware drives it: over SPI, with the control program the firmware
// carries (app/main/csp/control_program.hpp) loaded while the CSP is held, its
// constants and the patch written through the write queue, and the partials'
// pointers set. The writes are the firmware's own: app/main/render.cpp turns
// a patch (patch.h) and a note into registers and sinks, and this bench
// programs the chip with what it says. What comes out is checked as a
// listener would hear it: the pitch from the zero crossings, the level, the
// pan, the filter, the vibrato, the velocity, the release.
//
// Exit status 0: all pass.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "Vtb_synth.h"
#include "csp/control_program.hpp"
#include "csp/lfo.hpp"
#include "engine_image.hpp"
#include "fpga_map.hpp"
#include "patch.h"
#include "patch_file.h"
#include "render.hpp"
#include "svdpi.h"
#include "verilated.h"

namespace {

// ---- the clock, the SPI master and the audio tap ------------------------------------------

constexpr int pass_cycles = 1536;  // one CSP pass
constexpr int ms_cycles   = 73728; // a millisecond of system clocks
constexpr int spi_half    = 4; // system clocks per SCLK half period: 9.2 MHz
constexpr int sample_rate = 96000;

struct Sample {
    int left; // what the listener hears
    int right;
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
            samples_.push_back(
                    {signed24(top_.out_left), signed24(top_.out_right)});
        }
        tick_seen_ = top_.sample_tick;
    }

    void run(int64_t cycles) {
        for (int64_t n = 0; n < cycles; ++n) {
            cycle();
        }
    }
    void run_ms(double milliseconds) {
        run(static_cast<int64_t>(milliseconds * ms_cycles));
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
                got       = static_cast<uint8_t>((got << 1) | top_.miso);
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

    // Words to consecutive addresses in one frame.
    void write_burst(uint16_t address, const uint32_t *words, int count) {
        std::vector<uint8_t> out = {0x40, static_cast<uint8_t>(address >> 8),
                                    static_cast<uint8_t>(address)};
        for (int k = 0; k < count; ++k) {
            for (int shift = 24; shift >= 0; shift -= 8) {
                out.push_back(static_cast<uint8_t>(words[k] >> shift));
            }
        }
        frame(out);
    }

    uint32_t read(uint16_t address) {
        const std::vector<uint8_t> in =
                frame({0xC0, static_cast<uint8_t>(address >> 8),
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

private:
    Vtb_synth top_;
    std::vector<Sample> samples_;
    bool tick_seen_ = false;
};

// ---- the control plane, as the firmware speaks it ------------------------------------------

constexpr uint16_t ctrl_address = fpga_map::ctrl;
constexpr uint32_t ctrl_swap    = fpga_map::ctrl_swap;
constexpr uint32_t ctrl_hold    = fpga_map::ctrl_hold;

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

    void load() {
        for (size_t pc = 0; pc < csp::control::words.size(); ++pc) {
            synth_.write(fpga_map::program_high,
                         static_cast<uint32_t>(csp::control::words[pc] >> 32));
            synth_.write(static_cast<uint16_t>(fpga_map::program_base + pc),
                         static_cast<uint32_t>(csp::control::words[pc]));
        }
    }

    // Queue the writes (the queue holds 512) and commit them. Held, a pass
    // applies them all; running, 48 a pass.
    void commit(const render::Writes &writes, bool held) {
        constexpr size_t chunk = 256;
        for (size_t done = 0; done < writes.size();) {
            const size_t end = std::min(writes.size(), done + chunk);
            for (; done < end; ++done) {
                synth_.write(static_cast<uint16_t>(fpga_map::queue_base
                                                   + writes[done].address),
                             static_cast<uint32_t>(writes[done].raw) & 0x3FFFF);
            }
            synth_.write(ctrl_address, ctrl_swap | (held ? ctrl_hold : 0));
            synth_.run_passes(held ? 2 : 1 + static_cast<int>(chunk / 48));
        }
    }

    // A partial's ten pointers: three to a word, the fourth word commits.
    void point(int partial,
               const std::array<int, render::pointer_count> &pointers) {
        const uint16_t base = static_cast<uint16_t>(
                fpga_map::partial_base + fpga_map::partial_stride * partial);
        for (int word = 0; word < 3; ++word) {
            synth_.write(base + word,
                         static_cast<uint32_t>(pointers[3 * word])
                                 | static_cast<uint32_t>(pointers[3 * word + 1])
                                           << 10
                                 | static_cast<uint32_t>(pointers[3 * word + 2])
                                           << 20);
        }
        synth_.write(base + 3, static_cast<uint32_t>(pointers[9]));
    }

private:
    Synth &synth_;
};

// ---- the firmware's side: a patch on a synthesizer ------------------------------------------

// Everything the firmware does at start-up and per note, on one chip.
// The engine link's SPI port, on the simulated chip.
class SynthPort : public EnginePort {
public:
    explicit SynthPort(Synth &synth) : synth_(synth) {}
    void queue_burst(uint16_t address, const uint32_t *words,
                     int count) override {
        synth_.write_burst(address, words, count);
    }
    void write_register(uint16_t address, uint32_t value) override {
        synth_.write(address, value);
    }

private:
    Synth &synth_;
};

// Everything the firmware does at start-up and per note, on one chip, with the
// firmware's own register image and its 1 kHz tick.
class Rig {
public:
    explicit Rig(VerilatedContext &context)
        : synth(context), link(synth), port(synth) {
        patch_init(&patch);
    }

    // As engine_link_init and voice_alloc_init do: hold the CSP, load the
    // program, write the constants and the wiring, point the partials,
    // release it, then the patch.
    void bring_up() {
        link.hold();
        link.load();
        render::Writes writes;
        for (const csp::control::Constant &constant : csp::control::constants) {
            writes.push_back({constant.address, constant.raw});
        }
        render::setup(writes);
        send(writes);
        while (image.pending()) {
            image.send(port, fpga_map::queue_depth / 2, fpga_map::ctrl_hold);
            synth.run_passes(2);
        }
        point_partials();
        link.release();
        synth.run_passes(4);
        apply();
    }

    void patch_writes(render::Writes &writes) {
        render::amp_envelope(patch, writes);
        render::mod_envelope(patch, writes);
        render::cutoff(patch, controllers, writes);
        render::volume(patch, writes);
        render::pitch_bend(patch, controllers, writes);
        render::lfo(patch, 0, writes);
        render::lfo(patch, 1, writes);
        render::channel_sound(patch, writes);
    }

    // The patch as it is now, sent to a running chip.
    void apply() {
        render::Writes writes;
        patch_writes(writes);
        commit(writes);
        point_partials();
    }

    void point_partials() {
        render::VoicePlan plan;
        render::voicing(patch, plan);
        for (int voice = 0; voice < render::voice_count; ++voice) {
            for (int slot = 0; slot < render::partials_per_voice; ++slot) {
                link.point(voice * render::partials_per_voice + slot,
                           render::pointers_of(voice, slot, plan[slot]));
            }
        }
    }

    // A note on a voice.
    void strike(uint8_t note, uint8_t velocity = 100, int voice = 0) {
        render::Writes writes;
        render::note_on(patch, voice, note, velocity, writes);
        commit(writes);
    }

    void release_voice(int voice = 0) {
        render::Writes writes;
        render::gate(voice, false, writes);
        commit(writes);
    }

    void silence(int voice) {
        render::Writes writes;
        render::silence(voice, writes);
        commit(writes);
    }

    // Writes into the image, and the 1 kHz tick until it has sent them all.
    void commit(const render::Writes &writes) {
        send(writes);
        while (image.pending()) {
            image.send(port, 480, 0);
            synth.run_ms(1);
        }
        synth.run_ms(1);
    }

    Synth synth;
    Link link;
    SynthPort port;
    EngineImage image;
    patch_t patch;
    render::Controllers controllers;

private:
    void send(const render::Writes &writes) {
        for (const render::Write &write : writes) {
            image.set(write.address, write.raw, write.force);
        }
    }
};

// ---- measuring what comes out -------------------------------------------------------------------------

struct Window {
    double rms;
    double peak;
    double frequency; // from the rising zero crossings, Hz
};

double value_of(const Sample &sample, bool left) {
    return (left ? sample.left : sample.right) / 8388608.0;
}

Window measure(const std::vector<Sample> &samples, size_t first, size_t last,
               bool left = true) {
    double sum = 0, peak = 0;
    int crossings         = 0;
    size_t first_crossing = 0, last_crossing = 0;
    double previous = 0;
    for (size_t n = first; n < last; ++n) {
        const double value = value_of(samples[n], left);
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
        window.frequency = sample_rate * (crossings - 1)
                           / double(last_crossing - first_crossing);
    }
    return window;
}

// The magnitude of one frequency in a window (Goertzel), as a share of a
// full-scale sine's.
double component(const std::vector<Sample> &samples, size_t first, size_t last,
                 double frequency) {
    const double omega = 2.0 * M_PI * frequency / sample_rate;
    double real = 0, imag = 0;
    for (size_t n = first; n < last; ++n) {
        const double value = value_of(samples[n], true);
        real += value * std::cos(omega * double(n - first));
        imag += value * std::sin(omega * double(n - first));
    }
    return 2.0 * std::hypot(real, imag) / double(last - first);
}

int failures = 0;

void check(bool condition, const std::string &what) {
    std::printf("  %s: %s\n", condition ? "pass" : "FAIL", what.c_str());
    failures += !condition;
}

constexpr double c4 = 261.6256;

// A sine, one oscillator, centred, the envelope open: the plainest note.
void plain(patch_t &patch) {
    patch.voice_struct   = VOICE_2_PLAIN;
    patch.osc[0].wave    = WAVE_SINE;
    patch.osc_mix        = -63; // osc 2 out of it
    patch.filter.cascade = 0;
    patch.filter.cutoff  = 0x2B20 - (5 * 1024 + 512); // wide open
}

// Let a note settle (attack and decay are a few milliseconds) and measure 50 ms.
Window sustained(Rig &rig, bool left = true) {
    rig.synth.run_ms(40);
    const size_t from = rig.synth.mark();
    rig.synth.run_ms(50);
    return measure(rig.synth.samples(), from, rig.synth.mark(), left);
}

// ---- the cases -------------------------------------------------------------------------------------------------

void case_note(VerilatedContext &context) {
    std::printf("a note: pitch, level, release\n");
    Rig rig(context);
    plain(rig.patch);
    rig.bring_up();
    check(rig.synth.read(ctrl_address) == 0,
          "CTRL reads back what was written (released)");
    {
        const size_t from = rig.synth.mark();
        rig.synth.run_ms(5);
        check(measure(rig.synth.samples(), from, rig.synth.mark()).peak < 1e-4,
              "silent before a note");
    }
    rig.strike(60);
    const Window note = sustained(rig);
    std::printf("  %.2f Hz, peak %.4f, rms %.4f\n", note.frequency, note.peak,
                note.rms);
    check(std::fabs(note.frequency / c4 - 1.0) < 0.01,
          "middle C: 261.6 Hz within 1 %");
    // the level the firmware's gain staging says: the partial at volume code
    // 0xD7 (the anchor and the make-up for two partials), the envelope at
    // sustain (full), the sine's amplitude 1.09 of the mix scale (measured)
    const double expected = 1.09 * std::exp2((0xD7 - 255) / 16.0);
    check(std::fabs(note.peak / expected - 1.0) < 0.15,
          "the level follows the volume codes: peak "
                  + std::to_string(note.peak) + " against "
                  + std::to_string(expected));
    const Window right = measure(rig.synth.samples(), rig.synth.mark() - 4800,
                                 rig.synth.mark(), false);
    check(right.peak > 0.5 * note.peak,
          "centred: the right side sounds as the left does");

    rig.release_voice();
    const double tail_ms = render::release_tail_us(rig.patch) / 1000.0;
    rig.synth.run_ms(tail_ms);
    const size_t from = rig.synth.mark();
    rig.synth.run_ms(20);
    const Window tail = measure(rig.synth.samples(), from, rig.synth.mark());
    std::printf("  %.1f ms after the release: peak %.6f\n", tail_ms, tail.peak);
    check(tail.peak < note.peak * 0.01,
          "released: the note has died away within its tail");
}

void case_pitch(VerilatedContext &context) {
    std::printf("pitch: notes across the keyboard\n");
    for (const int note : {36, 48, 69, 72, 84}) {
        Rig rig(context);
        plain(rig.patch);
        rig.bring_up();
        rig.strike(static_cast<uint8_t>(note));
        const Window window = sustained(rig);
        const double want   = 440.0 * std::pow(2.0, (note - 69) / 12.0);
        std::printf("  note %d: %.2f Hz (want %.2f)\n", note, window.frequency,
                    want);
        check(std::fabs(window.frequency / want - 1.0) < 0.01, "within 1 %");
    }
}

void case_pan(VerilatedContext &context) {
    std::printf("pan\n");
    Rig rig(context);
    plain(rig.patch);
    rig.patch.pan = -63; // hard left (the right side is muted at -63)
    rig.bring_up();
    rig.strike(60);
    const Window left  = sustained(rig, true);
    const Window right = measure(rig.synth.samples(), rig.synth.mark() - 4800,
                                 rig.synth.mark(), false);
    std::printf("  left peak %.4f, right peak %.6f\n", left.peak, right.peak);
    check(left.peak > 0.02 && right.peak < left.peak * 0.01,
          "hard left: the right side is silent");

    // changed while the note sounds: both sink pages must take it
    rig.patch.pan = 63;
    rig.apply();
    rig.synth.run_ms(5);
    const size_t after = rig.synth.mark();
    rig.synth.run_ms(40);
    const Window now_left =
            measure(rig.synth.samples(), after, rig.synth.mark(), true);
    const Window now_right =
            measure(rig.synth.samples(), after, rig.synth.mark(), false);
    check(now_right.peak > 0.02 && now_left.peak < now_right.peak * 0.01,
          "pan thrown to the right while the note sounds: it stays there");
}

void case_filter(VerilatedContext &context) {
    std::printf("filter: the cutoff\n");
    double open_3rd = 0, closed_3rd = 0;
    for (const bool closed : {false, true}) {
        Rig rig(context);
        rig.patch.voice_struct   = VOICE_2_PLAIN;
        rig.patch.osc[0].wave    = WAVE_SAW;
        rig.patch.osc_mix        = -63;
        rig.patch.filter.cascade = 1; // 24 dB
        // closed: the cutoff at middle C itself (the knob's half octave is
        // added), a note and a half under the third harmonic
        rig.patch.filter.cutoff = closed ? -512 : 0x2B20 - (5 * 1024 + 512);
        rig.bring_up();
        rig.strike(60);
        rig.synth.run_ms(40);
        const size_t from = rig.synth.mark();
        rig.synth.run_ms(50);
        const double third =
                component(rig.synth.samples(), from, rig.synth.mark(), 3 * c4);
        (closed ? closed_3rd : open_3rd) = third;
    }
    std::printf("  third harmonic: open %.5f, closed %.5f\n", open_3rd,
                closed_3rd);
    check(closed_3rd < open_3rd * 0.1,
          "a cutoff at the note takes the third harmonic down by 20 dB at least");
}

void case_vibrato(VerilatedContext &context) {
    std::printf("LFO 1 on the pitch\n");
    Rig rig(context);
    plain(rig.patch);
    rig.patch.lfo[0].shape = 3;   // sine
    rig.patch.lfo[0].rate  = 700; // 2 Hz at 96 kHz
    if (const char *shape = std::getenv("SYNTH_LFO_SHAPE")) {
        rig.patch.lfo[0].shape = static_cast<uint8_t>(std::atoi(shape));
    }
    rig.patch.lfo[0].depth = 1024 / 6; // ±1 semitone
    rig.patch.lfo[0].dest  = LFO_DEST_PITCH;
    if (const char *which = std::getenv(
                "SYNTH_LFO_WHICH")) { // LFO 2 instead: the same, moved
        const int n = std::atoi(which);
        if (n != 0) {
            rig.patch.lfo[n]       = rig.patch.lfo[0];
            rig.patch.lfo[0].depth = 0;
            rig.patch.lfo[0].dest  = LFO_DEST_DUTY;
        }
    }
    const bool live = std::getenv("SYNTH_VIBRATO_LIVE") != nullptr;
    if (live) { // as the knobs do it: the LFO is brought to the pitch while a note sounds
        rig.patch.lfo[0].dest  = LFO_DEST_DUTY;
        rig.patch.lfo[0].depth = 0;
    }
    rig.bring_up();
    rig.strike(60);
    rig.synth.run_ms(20);
    if (live) {
        rig.synth.run_ms(300);
        rig.patch.lfo[0].depth = 1024 / 6;
        render::Writes writes;
        render::lfo(rig.patch, 0, writes);
        rig.commit(writes);
        rig.patch.lfo[0].dest = LFO_DEST_PITCH;
        writes.clear();
        render::lfo(rig.patch, 0, writes);
        rig.commit(writes);
    }
    // the frequency every 25 ms for a second
    double lowest = 1e9, highest = 0;
    for (int slice = 0; slice < 40; ++slice) {
        const size_t from = rig.synth.mark();
        rig.synth.run_ms(25);
        const Window window =
                measure(rig.synth.samples(), from, rig.synth.mark());
        if (window.frequency > 0) {
            lowest  = std::min(lowest, window.frequency);
            highest = std::max(highest, window.frequency);
        }
    }
    const double span = std::log2(highest / lowest) * 12.0;
    std::printf("  %.1f to %.1f Hz: %.2f semitones\n", lowest, highest, span);
    check(span > 1.6 && span < 2.4, "±1 semitone makes a span of 2");
}

// The register probe: the board's window into the CSP's registers.
void case_probe(VerilatedContext &context) {
    std::printf("the register probe\n");
    Rig rig(context);
    plain(rig.patch);
    rig.patch.lfo[0].rate = 700;
    rig.bring_up();
    // the pass counter (0x040, the even register of its pair) moves
    rig.synth.write(0x000C, 0x040);
    rig.synth.run_passes(3);
    const uint32_t first = rig.synth.read(0x000D);
    rig.synth.run_passes(5);
    const uint32_t second = rig.synth.read(0x000D);
    std::printf("  pass counter %u, then %u\n", first, second);
    check(second != first && second > 0,
          "the probe reads the pass counter, and it moves");
    // LFO 1's phase step, a wide register: the pair's even word is the high part
    const int step = csp::control::lfos + csp::control::phase_step;
    rig.synth.write(0x000C, static_cast<uint16_t>(step));
    rig.synth.run_passes(3);
    const int64_t want = csp::lfo_rate(700, 2);
    const uint64_t got =
            (uint64_t{rig.synth.read(0x000D)} << 18) | rig.synth.read(0x000E);
    std::printf("  phase step %llu, want %lld\n",
                static_cast<unsigned long long>(got),
                static_cast<long long>(want));
    check(static_cast<int64_t>(got) == want,
          "the probe reads LFO 1's phase step, both words");
}

void case_velocity(VerilatedContext &context) {
    std::printf("velocity scales the amp envelope\n");
    double loud = 0, soft = 0;
    for (const uint8_t velocity : {127, 64}) {
        Rig rig(context);
        plain(rig.patch);
        rig.patch.vel_amp_amt = 127;
        rig.bring_up();
        rig.strike(60, velocity);
        (velocity == 127 ? loud : soft) = sustained(rig).peak;
    }
    // g(64) = 64/127; the peak in dB is 60 dB × (1 − g) down
    const double want = std::pow(10.0, -3.0 * (1.0 - 64.0 / 127.0));
    std::printf("  soft / loud = %.4f (want %.4f)\n", soft / loud, want);
    check(std::fabs(soft / loud / want - 1.0) < 0.15,
          "a soft note is as many dB down as the patch says");
}

void case_unison(VerilatedContext &context) {
    std::printf("the voice structure: seven and one, detuned and spread\n");
    Rig rig(context);
    rig.patch.voice_struct  = VOICE_7_PLUS_1;
    rig.patch.osc[0].wave   = WAVE_SAW;
    rig.patch.osc[1].wave   = WAVE_SAW;
    rig.patch.osc_mix       = 0;
    rig.patch.unison_detune = 6;
    rig.patch.unison_stereo = 100;
    rig.patch.filter.cutoff = 0x2B20 - (5 * 1024 + 512);
    rig.bring_up();
    rig.strike(60);
    rig.synth.run_ms(40);
    const size_t from = rig.synth.mark();
    rig.synth.run_ms(100);
    const Window left =
            measure(rig.synth.samples(), from, rig.synth.mark(), true);
    const Window right =
            measure(rig.synth.samples(), from, rig.synth.mark(), false);
    std::printf("  left rms %.4f peak %.4f, right rms %.4f peak %.4f\n",
                left.rms, left.peak, right.rms, right.peak);
    check(left.rms > 0.01 && right.rms > 0.01,
          "eight partials sound on both sides");
    check(left.peak < 0.99 && right.peak < 0.99, "and do not rail the output");
    // seven saws a few steps apart beat: the level moves over the 100 ms
    double lowest = 1e9, highest = 0;
    for (int slice = 0; slice < 20; ++slice) {
        const Window window = measure(rig.synth.samples(), from + 480 * slice,
                                      from + 480 * (slice + 1), true);
        lowest              = std::min(lowest, window.rms);
        highest             = std::max(highest, window.rms);
    }
    check(highest > lowest * 1.05, "the unison beats");
}

// Several notes on several voices, struck and released: afterwards nothing
// sounds. (A board test found a hum left behind after a few notes.)
void case_several(VerilatedContext &context) {
    std::printf("several notes, all released\n");
    Rig rig(context);
    rig.bring_up(); // the init patch: a saw through the open 24 dB filter
    for (int round = 0; round < 3; ++round) {
        for (int voice = 0; voice < 6; ++voice) {
            rig.strike(static_cast<uint8_t>(48 + 4 * voice + round), 100,
                       voice);
            rig.synth.run_ms(15);
        }
        rig.synth.run_ms(60);
        for (int voice = 0; voice < 6; ++voice) {
            rig.release_voice(voice);
            rig.synth.run_ms(7);
        }
        rig.synth.run_ms(60);
    }
    rig.synth.run_ms(500);
    const size_t from = rig.synth.mark();
    rig.synth.run_ms(30);
    const Window left =
            measure(rig.synth.samples(), from, rig.synth.mark(), true);
    const Window right =
            measure(rig.synth.samples(), from, rig.synth.mark(), false);
    std::printf("  after the release: left peak %.6f, right peak %.6f\n",
                left.peak, right.peak);
    check(left.peak < 1e-3 && right.peak < 1e-3,
          "silent after every note is released");
}

// The factory startup patch, a long release, several notes: the sound of the
// board test (#222) in simulation.
void case_startup_patch(VerilatedContext &context) {
    std::printf("the startup patch: notes and their long releases\n");
    Rig rig(context);
    char error[160] = "";
    if (!patch_file_read(STARTUP_PATCH, &rig.patch, error, sizeof error)) {
        std::printf("  cannot read the patch: %s\n", error);
        check(false, "the startup patch loads");
        return;
    }
    if (std::getenv("SYNTH_FAST_RELEASE")) {
        rig.patch.env[0].release = 0xB0; // a few hundred ms
        rig.patch.env[1].release = 0xB0;
    }
    rig.bring_up();
    for (int voice = 0; voice < 4; ++voice) {
        rig.strike(static_cast<uint8_t>(48 + 5 * voice), 100, voice);
        rig.synth.run_ms(40);
    }
    rig.synth.run_ms(200);
    const size_t held_from = rig.synth.mark() - 4800;
    const Window held =
            measure(rig.synth.samples(), held_from, rig.synth.mark());
    for (int voice = 0; voice < 4; ++voice) {
        rig.release_voice(voice);
    }
    // The patch's release is 11 s. The gain it was written for fell by
    // 60 dB × (1 − level): 30 dB down after a second, 51 after three. Follow
    // the note for three seconds (a second takes a minute of simulation).
    double previous = held.peak;
    for (int second = 1; second <= 3; ++second) {
        const size_t from = rig.synth.mark();
        rig.synth.run_ms(1000);
        const double peak =
                measure(rig.synth.samples(), from, rig.synth.mark()).peak;
        std::printf("  second %d after the release: peak %.5f (%.1f dB)\n",
                    second, peak, 20.0 * std::log10(peak / held.peak));
        previous = peak;
    }
    const double fallen_db = 20.0 * std::log10(previous / held.peak);
    std::printf("  held peak %.4f; %.1f dB down after 3 s\n", held.peak,
                fallen_db);
    check(fallen_db < -40.0,
          "three seconds after the release the note is 40 dB down at least");
    check(fallen_db > -75.0, "and has not been cut off");
}

// Notes struck and released as fast as a controller sends them, across all
// 32 voices, through the firmware's image and its 1 kHz tick: once they are
// all released nothing sounds. A lost gate write would leave a voice
// sustaining for good (a board test heard a release that never finished).
void case_stress(VerilatedContext &context) {
    std::printf("32 voices struck and released at random\n");
    Rig rig(context);
    rig.bring_up();
    std::array<bool, render::voice_count> held{};
    uint32_t seed = 12345;
    auto random   = [&]() {
        seed = seed * 1664525u + 1013904223u;
        return seed >> 8;
    };
    for (int tick = 0; tick < 400; ++tick) {
        render::Writes writes;
        for (int event = 0; event < 3; ++event) {
            const int voice = static_cast<int>(random() % render::voice_count);
            if (held[voice]) {
                render::gate(voice, false, writes);
            } else {
                render::note_on(rig.patch, voice,
                                static_cast<uint8_t>(36 + random() % 48),
                                static_cast<uint8_t>(40 + random() % 80),
                                writes);
            }
            held[voice] = !held[voice];
        }
        for (const render::Write &write : writes) {
            rig.image.set(write.address, write.raw, write.force);
        }
        rig.image.send(rig.port, 480, 0);
        rig.synth.run_ms(1);
    }
    for (int voice = 0; voice < render::voice_count; ++voice) {
        if (held[voice]) {
            rig.release_voice(voice);
        }
    }
    rig.synth.run_ms(800);
    const size_t from = rig.synth.mark();
    rig.synth.run_ms(30);
    const Window left =
            measure(rig.synth.samples(), from, rig.synth.mark(), true);
    std::printf("  after the last release: peak %.6f\n", left.peak);
    check(left.peak < 1e-3, "silent once every voice is released");
}

} // namespace

int main(int argc, char **argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    std::printf("control program: %zu instructions, %zu constants\n",
                csp::control::words.size(), csp::control::constants.size());
    if (std::getenv("SYNTH_ONLY_STRESS")) {
        case_stress(context);
        std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
        return failures == 0 ? 0 : 1;
    }
    if (std::getenv("SYNTH_ONLY_PROBE")) {
        case_probe(context);
        std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
        return failures == 0 ? 0 : 1;
    }
    if (std::getenv("SYNTH_ONLY_VIBRATO")) {
        case_vibrato(context);
        std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
        return failures == 0 ? 0 : 1;
    }
    if (std::getenv("SYNTH_ONLY_STARTUP")) {
        case_startup_patch(context);
        std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
        return failures == 0 ? 0 : 1;
    }
    case_note(context);
    case_pitch(context);
    case_pan(context);
    case_filter(context);
    case_vibrato(context);
    case_probe(context);
    case_velocity(context);
    case_unison(context);
    case_several(context);
    case_stress(context);
    case_startup_patch(context);
    std::printf(failures == 0 ? "ALL PASS\n" : "%d FAILURE(S)\n", failures);
    return failures == 0 ? 0 : 1;
}
