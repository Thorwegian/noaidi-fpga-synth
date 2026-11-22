// cc_map_test.cpp — the CC schema reads back what it wrote (host test)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// For every preset CC and every one of its 128 values: apply it to the init
// preset, dump the result as CCs, apply that dump to a fresh init preset, and
// the two presets must be the same. The dump is also checked to name every
// CC exactly once (the RPN's selects aside), with the panel's values for the
// switches. The factory presets are dumped and re-applied too; where a file
// holds a value no knob reaches, the difference is printed, not failed.
//
//   cc_map_test [preset.toml ...]

#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "cc_map.hpp"
#include "preset.h"
#include "preset_file.h"

namespace {

int g_failures = 0;

void check(bool ok, const std::string &what) {
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        ++g_failures;
    }
}

struct Message {
    uint8_t cc, value;
};

// A dump's messages, collected into a fixed buffer (a dump is dump_length()
// long, and a vector growing under the callback trips a false
// -Wstringop-overflow in GCC 13).
struct Collected {
    std::array<Message, 256> items{};
    int count = 0;
};

void collect(uint8_t cc, uint8_t value, void *user) {
    Collected &c = *static_cast<Collected *>(user);
    if (c.count < static_cast<int>(c.items.size())) {
        c.items[c.count++] = {cc, value};
    }
}

std::vector<Message> dump_of(const preset_t &preset,
                             const cc_map::Knobs &knobs) {
    Collected collected;
    cc_map::dump(preset, knobs, collect, &collected);
    return std::vector<Message>(collected.items.begin(),
                                collected.items.begin() + collected.count);
}

// The preset a dump describes: every message applied to the init preset, in order.
preset_t preset_of(const std::vector<Message> &messages) {
    preset_t preset;
    preset_init(&preset);
    cc_map::Knobs knobs = cc_map::knobs_of(preset);
    for (const Message &m : messages) {
        if (m.cc == 6) {
            // RPN 0/0 data entry: the caller's, in the firmware
            preset.part.bend_range = m.value;
        } else {
            cc_map::apply(preset, knobs, m.cc, m.value);
        }
    }
    return preset;
}

// The fields the schema reaches that differ, as one line; empty when none do.
std::string differences(const preset_t &a, const preset_t &b) {
    std::string out;
    auto field = [&](const std::string &name, double x, double y) {
        if (x != y) {
            char values[64];
            std::snprintf(values, sizeof values, " %.9g vs %.9g", x, y);
            out += (out.empty() ? "" : ", ") + name + values;
        }
    };
    field("voice.structure", a.voice.structure, b.voice.structure);
    field("voice.osc_mix", a.voice.osc_mix, b.voice.osc_mix);
    field("voice.unison_detune", a.voice.unison_detune, b.voice.unison_detune);
    field("voice.unison_stereo", a.voice.unison_stereo, b.voice.unison_stereo);
    for (int i = 0; i < 2; ++i) {
        const std::string o = "osc" + std::to_string(i + 1) + ".";
        field(o + "wave", a.osc[i].wave, b.osc[i].wave);
        field(o + "tune", a.osc[i].tune, b.osc[i].tune);
        field(o + "pulse_width", a.osc[i].pulse_width, b.osc[i].pulse_width);
    }
    field("filter.type", a.filter.type, b.filter.type);
    field("filter.slope", a.filter.slope, b.filter.slope);
    field("filter.cutoff", a.filter.cutoff, b.filter.cutoff);
    field("filter.resonance", a.filter.resonance, b.filter.resonance);
    field("filter.key_track", a.filter.key_track, b.filter.key_track);
    field("amp_env.attack", a.amp_env.attack, b.amp_env.attack);
    field("amp_env.sustain", a.amp_env.sustain, b.amp_env.sustain);
    field("amp_env.decay", a.amp_env.decay, b.amp_env.decay);
    field("amp_env.release", a.amp_env.release, b.amp_env.release);
    field("amp_env.velocity", a.amp_env.velocity, b.amp_env.velocity);
    field("mod_env.attack", a.mod_env.attack, b.mod_env.attack);
    field("mod_env.sustain", a.mod_env.sustain, b.mod_env.sustain);
    field("mod_env.decay", a.mod_env.decay, b.mod_env.decay);
    field("mod_env.release", a.mod_env.release, b.mod_env.release);
    field("mod_env.velocity", a.mod_env.velocity, b.mod_env.velocity);
    field("mod_env.depth", a.mod_env.depth, b.mod_env.depth);
    field("mod_env.pitch", a.mod_env.pitch, b.mod_env.pitch);
    for (int i = 0; i < 2; ++i) {
        const std::string l = "lfo" + std::to_string(i + 1) + ".";
        field(l + "shape", a.lfo[i].shape, b.lfo[i].shape);
        field(l + "rate", a.lfo[i].rate, b.lfo[i].rate);
        field(l + "destination", a.lfo[i].destination, b.lfo[i].destination);
        field(l + "depth", a.lfo[i].depth, b.lfo[i].depth);
    }
    field("part.volume", a.part.volume, b.part.volume);
    field("part.pan", a.part.pan, b.part.pan);
    field("part.bend_range", a.part.bend_range, b.part.bend_range);
    return out;
}

void test_dump_shape() {
    preset_t preset;
    preset_init(&preset);
    const std::vector<Message> messages =
            dump_of(preset, cc_map::knobs_of(preset));
    check(static_cast<int>(messages.size()) == cc_map::dump_length(),
          "the dump has dump_length() messages: "
                  + std::to_string(messages.size()));
    std::map<int, int> seen;
    for (const Message &m : messages) {
        ++seen[m.cc];
    }
    for (const auto &[cc, count] : seen) {
        const int allowed =
                (cc == 101 || cc == 100) ? 2 : 1; // the RPN select and its null
        check(count == allowed, "CC " + std::to_string(cc) + " is named once: "
                                        + std::to_string(count));
    }
    // coarse before fine, a destination before its depth knobs
    auto position = [&](int cc) {
        for (size_t i = 0; i < messages.size(); ++i) {
            if (messages[i].cc == cc) {
                return static_cast<int>(i);
            }
        }
        return -1;
    };
    check(position(74) < position(106), "cutoff coarse before fine");
    check(position(14) < position(15) && position(22) < position(23),
          "tune coarse before fine");
    check(position(114) < position(77) && position(77) < position(115),
          "LFO 1 destination, coarse, fine");
    check(position(112) < position(110) && position(110) < position(116),
          "LFO 2 destination, coarse, fine");
    // the switches read as the panel's positions
    for (const Message &m : messages) {
        switch (m.cc) {
        case 20:
        case 21:
        case 113:
        case 111:
        case 114:
        case 112:
            check(m.value % 32 == 0,
                  "a four-way switch sits at 0, 32, 64 or 96: CC "
                          + std::to_string(m.cc));
            break;
        case 26:
        case 29:
            check(m.value == 0 || m.value == 64 || m.value == 127,
                  "a three-way switch sits at 0, 64 or 127");
            break;
        case 30:
            check(m.value == 0 || m.value == 127,
                  "the slope switch sits at 0 or 127");
            break;
        default:
            break;
        }
    }
}

void test_cutoff_grid() {
    // CC 74 is a note: a coarse step is a semitone and the fine is the
    // 128ths of the one above it, so the pair's position is readable.
    preset_t preset;
    preset_init(&preset);
    cc_map::Knobs knobs;
    check(cc_map::apply(preset, knobs, 74, 60), "CC 74 is a preset CC");
    const float on_middle_c = preset.filter.cutoff;
    check(std::fabs(on_middle_c - 261.6256f) < 0.05f,
          "CC 74 = 60 puts the cutoff on middle C");
    check(cc_map::apply(preset, knobs, 74, 61), "CC 74 = 61 applies");
    check(std::fabs(preset.filter.cutoff / on_middle_c
                    - std::exp2(1.0f / 12.0f))
                  < 1e-4f,
          "a coarse step is a semitone");
    check(cc_map::apply(preset, knobs, 106, 64), "CC 106 applies");
    check(std::fabs(preset.filter.cutoff / on_middle_c
                    - std::exp2((1.0f + 64.0f / 128.0f) / 12.0f))
                  < 1e-4f,
          "the fine is the 128ths of a semitone");
}

void test_round_trip() {
    // The baseline is the init preset within the knobs' reach: preset_init()
    // holds a few values no knob lands on (a decay of 0.59 s where the knob's
    // nearest is another), which is the file's resolution, not the map's.
    // One dump and apply brings it onto the knobs' positions.
    preset_t raw;
    preset_init(&raw);
    const preset_t init = preset_of(dump_of(raw, cc_map::knobs_of(raw)));
    const std::string init_diff = differences(raw, init);
    if (!init_diff.empty()) {
        std::printf("  the init preset, beyond the knobs' reach: %s\n",
                    init_diff.c_str());
    }
    check(differences(init, preset_of(dump_of(init, cc_map::knobs_of(init))))
                  .empty(),
          "a preset within the knobs' reach reads back exactly");
    const std::vector<Message> ccs = dump_of(init, cc_map::knobs_of(init));
    int trips                      = 0;
    for (const Message &which : ccs) {
        if (which.cc == 101 || which.cc == 100 || which.cc == 6) {
            continue; // the RPN is applied by the firmware, not the map
        }
        for (int value = 0; value < 128; ++value) {
            preset_t preset     = init;
            cc_map::Knobs knobs = cc_map::knobs_of(preset);
            check(cc_map::apply(preset, knobs, which.cc,
                                static_cast<uint8_t>(value)),
                  "CC " + std::to_string(which.cc) + " is a preset CC");
            const preset_t back    = preset_of(dump_of(preset, knobs));
            const std::string diff = differences(preset, back);
            check(diff.empty(), "CC " + std::to_string(which.cc) + " = "
                                        + std::to_string(value)
                                        + " reads back: " + diff);
            ++trips;
        }
    }
    std::printf("%d round trips of one CC on the init preset\n", trips);
}

// A loaded preset: dump → apply reproduces it where knobs reach; elsewhere the
// difference is the file's own resolution, printed.
void test_factory_preset(const char *path) {
    preset_t preset;
    std::string error;
    if (!preset_file::read(path, preset, error)) {
        check(false, std::string("read ") + path + ": " + error);
        return;
    }
    const preset_t back = preset_of(dump_of(preset, cc_map::knobs_of(preset)));
    const std::string diff = differences(preset, back);
    if (!diff.empty()) {
        std::printf("  %s: beyond the knobs' reach: %s\n", path, diff.c_str());
    }
}

} // namespace

int main(int argc, char **argv) {
    test_dump_shape();
    test_cutoff_grid();
    test_round_trip();
    for (int i = 1; i < argc; ++i) {
        test_factory_preset(argv[i]);
    }
    if (g_failures == 0) {
        std::printf("cc_map: ALL PASS\n");
        return 0;
    }
    std::printf("cc_map: FAIL (%d failures)\n", g_failures);
    return 1;
}
