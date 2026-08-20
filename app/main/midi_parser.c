// midi_parser.c — MIDI byte-stream parser (pure, hardware-independent)
//
// See midi_parser.h for the protocol behaviour. This module has no
// hardware dependencies and no heap usage — it can later be reused
// unchanged for other MIDI transports (USB MIDI, BLE MIDI, ...).

#include "midi_parser.h"

void midi_parser_init(midi_parser_t *p, midi_msg_cb_t cb, void *user)
{
    p->on_message = cb;
    p->user = user;
    midi_parser_reset(p);
}

void midi_parser_reset_partial(midi_parser_t *p)
{
    p->data_count = 0;
    p->in_sysex = false;
}

void midi_parser_reset(midi_parser_t *p)
{
    p->running_status = 0;
    p->data_count = 0;
    p->data_len = 0;
    p->in_sysex = false;
}

void midi_parser_feed(midi_parser_t *p, uint8_t byte)
{
    // ── System Real-Time (F8..FF) ──────────────────────────────────
    // May appear anywhere, including between the bytes of a running
    // message or inside SysEx. Ignored; never touch parser state.
    // FF (System Reset) additionally cancels Running Status.
    if (byte >= 0xF8) {
        if (byte == 0xFF) {
            p->running_status = 0;
            p->data_count = 0;
        }
        return;
    }

    // ── System Common (F0..F7) ─────────────────────────────────────
    // All of these cancel Running Status. SysEx payload is dropped
    // until the terminating F7.
    if (byte >= 0xF0) {
        if (byte == 0xF0) {
            p->in_sysex = true;
        } else if (byte == 0xF7) {
            p->in_sysex = false;
        }
        p->running_status = 0;
        p->data_count = 0;
        return;
    }

    // ── SysEx payload ──────────────────────────────────────────────
    if (p->in_sysex) {
        return; // drop everything until F7
    }

    // ── Channel voice status (80..EF) ─────────────────────────────
    if (byte >= 0x80) {
        p->running_status = byte;
        p->data_count = 0;
        uint8_t type = byte & 0xF0;
        p->data_len = (type == 0xC0 || type == 0xD0) ? 1 : 2;
        return;
    }

    // ── Data byte (00..7F) ─────────────────────────────────────────
    if (p->running_status == 0) {
        return; // orphan data byte, nothing to attach it to
    }

    p->data[p->data_count++] = byte;
    if (p->data_count < p->data_len) {
        return; // message not complete yet
    }

    midi_message_t msg = {
        .status = p->running_status,
        .len = p->data_len,
        .data = {p->data[0], p->data[1]},
    };
    p->data_count = 0; // Running Status: next data byte starts a new message

    // Note On with velocity 0 == Note Off (MIDI convention)
    if ((msg.status & 0xF0) == 0x90 && msg.data[1] == 0) {
        msg.status = 0x80 | (msg.status & 0x0F);
    }

    if (p->on_message) {
        p->on_message(&msg, p->user);
    }
}
