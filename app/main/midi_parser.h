// midi_parser.h — MIDI byte-stream parser (pure, hardware-independent)
//
// Turns a serial byte stream into complete channel-voice messages via a
// callback. Handles the protocol edge cases that real hardware throws at
// you:
//   - Running Status (omitted status byte reuses the previous one)
//   - System Real-Time interleaved anywhere (F8 clock, FE Active
//     Sensing, FA/FC start/stop, ...) — never breaks a message in
//     progress
//   - System Common (F0 SysEx, F1/F2/F3, F6, F7) cancels Running Status
//   - SysEx payload discarded until F7
//   - Note On with velocity 0 normalised to Note Off (the MIDI
//     convention many keyboards use)
//   - Orphan data bytes (no Running Status) discarded

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One complete channel-voice message.
//
// status: full status byte including channel (0x80..0xEF)
// len:    number of valid data bytes (1 for Program Change /
//         Channel Aftertouch, 2 for everything else)
// data:   payload; data[1] is only valid when len == 2
typedef struct {
    uint8_t status;
    uint8_t len;
    uint8_t data[2];
} midi_message_t;

// Called for every complete channel-voice message.
typedef void (*midi_msg_cb_t)(const midi_message_t *msg, void *user);

typedef struct {
    midi_msg_cb_t on_message; // callback, may be NULL to count silently
    void *user;

    uint8_t running_status; // 0 = none
    uint8_t data_count;
    uint8_t data_len;
    uint8_t data[2];
    bool in_sysex;
} midi_parser_t;

void midi_parser_init(midi_parser_t *p, midi_msg_cb_t cb, void *user);

// Drop any half-received message (pending data bytes, SysEx in
// progress). Running Status is kept, so spec-legal Running Status
// reuse across silence still decodes. Call when the wire has been
// quiet for longer than any legal inter-byte gap.
void midi_parser_reset_partial(midi_parser_t *p);

// Full reset to the post-init state. Call when the MIDI source is
// considered gone (long silence, cable pulled, keyboard powered off).
void midi_parser_reset(midi_parser_t *p);

// Feed one byte. Reentrant per-instance, not thread-safe per-instance.
void midi_parser_feed(midi_parser_t *p, uint8_t byte);

#ifdef __cplusplus
}
#endif
