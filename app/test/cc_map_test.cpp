// cc_map_test.cpp — the CC schema reads back what it wrote (host test)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// For every patch CC and every one of its 128 values: apply it to the init
// patch, dump the result as CCs, apply that dump to a fresh init patch, and
// the two patches must be the same. The dump is also checked to name every
// CC exactly once (the RPN's selects aside), with the panel's values for the
// switches. The factory patches are dumped and re-applied too; where a file
// holds a value no knob reaches, the difference is printed, not failed.
//
//   cc_map_test [patch.toml ...]

#include <array>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "cc_map.hpp"
#include "patch.h"
#include "patch_file.h"

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

std::vector<Message> dump_of(const patch_t &patch, const cc_map::Knobs &knobs) {
    Collected collected;
    cc_map::dump(patch, knobs, collect, &collected);
    return std::vector<Message>(collected.items.begin(),
                                collected.items.begin() + collected.count);
}

// The patch a dump describes: every message applied to the init patch, in order.
patch_t patch_of(const std::vector<Message> &messages) {
    patch_t patch;
    patch_init(&patch);
    cc_map::Knobs knobs = cc_map::knobs_of(patch);
    for (const Message &m : messages) {
        if (m.cc == 6) {
            patch.bend_range =
                    m.value; // RPN 0/0 data entry: the caller's, in the firmware
        } else {
            cc_map::apply(patch, knobs, m.cc, m.value);
        }
    }
    return patch;
}

// The fields the schema reaches that differ, as one line; empty when none do.
std::string differences(const patch_t &a, const patch_t &b) {
    std::string out;
    auto field = [&](const char *name, long long x, long long y) {
        if (x != y) {
            out += (out.empty() ? "" : ", ") + std::string(name) + " "
                   + std::to_string(x) + " vs " + std::to_string(y);
        }
    };
    for (int i = 0; i < 2; ++i) {
        const std::string o = "osc" + std::to_string(i + 1) + ".";
        field((o + "wave").c_str(), a.osc[i].wave, b.osc[i].wave);
        field((o + "tune").c_str(), a.osc[i].tune, b.osc[i].tune);
        field((o + "duty").c_str(), a.osc[i].duty, b.osc[i].duty);
    }
    field("voice_struct", a.voice_struct, b.voice_struct);
    field("osc_mix", a.osc_mix, b.osc_mix);
    field("unison_detune", a.unison_detune, b.unison_detune);
    field("unison_stereo", a.unison_stereo, b.unison_stereo);
    field("filter.cutoff", a.filter.cutoff, b.filter.cutoff);
    field("filter.resonance", a.filter.resonance, b.filter.resonance);
    field("filter.type", a.filter.type, b.filter.type);
    field("filter.cascade", a.filter.cascade, b.filter.cascade);
    field("filter.key_track", a.filter.key_track, b.filter.key_track);
    for (int i = 0; i < 2; ++i) {
        const std::string e = "env" + std::to_string(i + 1) + ".";
        field((e + "attack").c_str(), a.env[i].attack, b.env[i].attack);
        field((e + "decay").c_str(), a.env[i].decay, b.env[i].decay);
        field((e + "sustain").c_str(), a.env[i].sustain, b.env[i].sustain);
        field((e + "release").c_str(), a.env[i].release, b.env[i].release);
    }
    field("mod_env_dest", a.mod_env_dest, b.mod_env_dest);
    field("mod_env_depth", a.mod_env_depth, b.mod_env_depth);
    for (int i = 0; i < 2; ++i) {
        const std::string l = "lfo" + std::to_string(i + 1) + ".";
        field((l + "shape").c_str(), a.lfo[i].shape, b.lfo[i].shape);
        field((l + "rate").c_str(), a.lfo[i].rate, b.lfo[i].rate);
        field((l + "depth").c_str(), a.lfo[i].depth, b.lfo[i].depth);
        field((l + "dest").c_str(), a.lfo[i].dest, b.lfo[i].dest);
    }
    field("vel_amp_amt", a.vel_amp_amt, b.vel_amp_amt);
    field("vel_mod_amt", a.vel_mod_amt, b.vel_mod_amt);
    field("bend_range", a.bend_range, b.bend_range);
    field("volume", a.volume, b.volume);
    field("pan", a.pan, b.pan);
    return out;
}

void test_dump_shape() {
    patch_t patch;
    patch_init(&patch);
    const std::vector<Message> messages =
            dump_of(patch, cc_map::knobs_of(patch));
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
        case 108:
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

void test_round_trip() {
    // The baseline is the init patch within the knobs' reach: patch_init()
    // holds a few values no knob lands on (an odd rate code, a sustain of
    // 1023 where the knob steps by eight), which is the file's resolution,
    // not the map's. One dump and apply brings it onto the knobs' grid.
    patch_t raw;
    patch_init(&raw);
    const patch_t init          = patch_of(dump_of(raw, cc_map::knobs_of(raw)));
    const std::string init_diff = differences(raw, init);
    if (!init_diff.empty()) {
        std::printf("  the init patch, beyond the knobs' reach: %s\n",
                    init_diff.c_str());
    }
    check(differences(init, patch_of(dump_of(init, cc_map::knobs_of(init))))
                  .empty(),
          "a patch within the knobs' reach reads back exactly");
    const std::vector<Message> ccs = dump_of(init, cc_map::knobs_of(init));
    int trips                      = 0;
    for (const Message &which : ccs) {
        if (which.cc == 101 || which.cc == 100 || which.cc == 6) {
            continue; // the RPN is applied by the firmware, not the map
        }
        for (int value = 0; value < 128; ++value) {
            patch_t patch           = init;
            cc_map::Knobs knobs     = cc_map::knobs_of(patch);
            const cc_map::Part part = cc_map::apply(
                    patch, knobs, which.cc, static_cast<uint8_t>(value));
            check(part != cc_map::Part::none,
                  "CC " + std::to_string(which.cc) + " is a patch CC");
            const patch_t back     = patch_of(dump_of(patch, knobs));
            const std::string diff = differences(patch, back);
            check(diff.empty(), "CC " + std::to_string(which.cc) + " = "
                                        + std::to_string(value)
                                        + " reads back: " + diff);
            ++trips;
        }
    }
    std::printf("%d round trips of one CC on the init patch\n", trips);
}

// A loaded patch: dump → apply reproduces it where knobs reach; elsewhere the
// difference is the file's own resolution, printed.
void test_factory_patch(const char *path) {
    patch_t patch;
    std::string error;
    if (!patch_file::read(path, patch, error)) {
        check(false, std::string("read ") + path + ": " + error);
        return;
    }
    const patch_t back     = patch_of(dump_of(patch, cc_map::knobs_of(patch)));
    const std::string diff = differences(patch, back);
    if (!diff.empty()) {
        std::printf("  %s: beyond the knobs' reach: %s\n", path, diff.c_str());
    }
}

} // namespace

int main(int argc, char **argv) {
    test_dump_shape();
    test_round_trip();
    for (int i = 1; i < argc; ++i) {
        test_factory_patch(argv[i]);
    }
    if (g_failures == 0) {
        std::printf("cc_map: ALL PASS\n");
        return 0;
    }
    std::printf("cc_map: FAIL (%d failures)\n", g_failures);
    return 1;
}
