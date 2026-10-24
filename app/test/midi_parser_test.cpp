// midi_parser_test.cpp — the MIDI byte-stream parser on the host
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The protocol's edge cases, as bytes: running status, real-time bytes
// inside a message and inside SysEx, a SysEx frame delivered whole, one that
// outgrows the buffer dropped, one cut short by a status byte dropped,
// running status cancelled by SysEx.

#include <cstdio>
#include <string>
#include <vector>

#include "midi_parser.h"

namespace {

int g_failures = 0;

void check(bool ok, const std::string &what) {
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        ++g_failures;
    }
}

struct Seen {
    std::vector<midi_message_t> messages;
    std::vector<std::vector<uint8_t>> frames;
};

void on_message(const midi_message_t *m, void *user) {
    static_cast<Seen *>(user)->messages.push_back(*m);
}

void on_sysex(const uint8_t *payload, uint8_t length, void *user) {
    static_cast<Seen *>(user)->frames.emplace_back(payload, payload + length);
}

Seen feed(const std::vector<uint8_t> &bytes) {
    Seen seen;
    midi_parser_t parser;
    midi_parser_init(&parser, on_message, &seen);
    midi_parser_on_sysex(&parser, on_sysex);
    for (const uint8_t byte : bytes) {
        midi_parser_feed(&parser, byte);
    }
    return seen;
}

} // namespace

int main() {
    {
        const Seen s = feed({0x90, 60, 100, 64, 100, 0xFE, 60, 0});
        check(s.messages.size() == 3,
              "running status: three messages from one status byte");
        check(s.messages.size() == 3 && s.messages[2].status == 0x80,
              "velocity 0 is a note-off");
        check(s.frames.empty(), "no SysEx seen");
    }
    {
        const Seen s =
                feed({0xF0, 0x7D, 0x4E, 0x4F, 0xF8, 0x10, 0xF7, 0xB0, 74, 100});
        check(s.frames.size() == 1, "a SysEx frame is delivered whole");
        check(s.frames.size() == 1
                      && s.frames[0]
                                 == std::vector<uint8_t>{0x7D, 0x4E, 0x4F,
                                                         0x10},
              "the frame is the bytes between F0 and F7, the real-time byte inside it skipped");
        check(s.messages.size() == 1 && s.messages[0].status == 0xB0,
              "a message after the frame parses");
    }
    {
        std::vector<uint8_t> bytes{0xF0};
        for (int i = 0; i < MIDI_SYSEX_MAX + 1; ++i) {
            bytes.push_back(0x01);
        }
        bytes.push_back(0xF7);
        bytes.insert(bytes.end(), {0xF0, 0x7D, 0x4E, 0x4F, 0x10, 0xF7});
        const Seen s = feed(bytes);
        check(s.frames.size() == 1,
              "a frame that outgrows the buffer is dropped, the next one is not");
    }
    {
        const Seen s = feed({0x90, 60, 100, 0xF0, 0x7D, 0x4E, 0x90, 64, 100});
        check(s.frames.empty(),
              "a frame cut short by a status byte is dropped");
        check(s.messages.size() == 2,
              "the status byte that cut it starts a message");
    }
    {
        const Seen s = feed({0x90, 60, 100, 0xF0, 0xF7, 64, 100});
        check(s.messages.size() == 1,
              "SysEx cancels running status: the data bytes after it are orphans");
    }
    if (g_failures == 0) {
        std::printf("midi_parser: ALL PASS\n");
        return 0;
    }
    std::printf("midi_parser: FAIL (%d failures)\n", g_failures);
    return 1;
}
