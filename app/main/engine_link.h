// engine_link.h — the single owner of the FPGA SPI link
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Everything the synth engine hears goes through here: a command
// queue mutates a local image of the per-element parameter space, and
// a fixed 1 kHz tick writes the dirty words to the shadow bank and
// swaps. Nothing else in the firmware may call fpga_word_write()/
// fpga_swap() once this is initialized.
//
// Shadow discipline (implemented here, in exactly one place): after a
// swap the new shadow holds the previous generation, so each tick
// writes this tick's dirty words UNION last tick's dirty words before
// swapping — the shadow catches up on the generation it missed.
// Callers never think about banks.

#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ENGINE_NUM_ELEMENTS 256
#define ENGINE_WORDS_PER_ELEMENT 7   // OSC DUTY FILTER GAIN GATE PTRS0 PTRS1
// GAIN word: volume UQ4.4 per channel — 0x00 = silence/
// exact mute, 0xFF = loudest; positive gain-bus values mean LOUDER.
// FILTER word: [13:0] cutoff UQ4.10 log2; [27:14] resonance UQ4.10
// log2 — octaves of Q above Butterworth (0 = Butterworth, ~1 integer
// = +6 dB of resonant peak, top of range = self-oscillation);
// [31:28] reserved.

typedef struct {
    uint8_t  elem;    // element index 0..255
    uint8_t  word;    // 0..6 (OSC DUTY FILTER GAIN GATE PTRS0 PTRS1)
    uint32_t value;
} engine_param_cmd_t;

// Mutes every element into the local image, writes both banks (two
// full-image writes with a swap between), and starts the 1 kHz tick
// task. Call after fpga_spi_init(). The boot image goes silent here.
// Bus pointers initialize to 0 (no modulation); the bus plan — which
// pointer targets which bus — is entirely voice_alloc's convention,
// pushed as ordinary PTRS0/PTRS1 commands at its init.
void engine_link_init(void);

// Queue one parameter write. Non-blocking: returns false if the queue
// is full (the write is dropped).
bool engine_link_param_write(const engine_param_cmd_t *cmd);

// Queue one live bus-base write (bus_architecture.md). Buses are not
// banked and need no swap: the write goes straight to the bus base
// register (0x0800 + bus) on the next tick. Value is signed Q8.10 in
// the low 18 bits. Bus 0 is hardwired zero and cannot be written.
bool engine_link_dmem_write(uint16_t dmem_addr, uint32_t value_q810);

// ── Producer table (B4/B5) ──────────────────────────────────────────
// 256 instructions x 4 words (stride 4) at 0x0100, banked like
// parameters (config is wiring): writes land in the shadow and take
// effect at the swap, with the same catch-up mirroring as the
// element image.
//   word 0 CFG:   [3:0] opcode bitmask (CSP_OPC_* below), [5:4] LFO shape
//                 (saw/pulse/tri/sine), [15:6] target bus,
//                 LFO:  [31:16] rate (UQ0.24 increment low bits:
//                       5.7 mHz steps, 375 Hz max)
//                 ADSR: [25:16] gate bus (level-sensitive: > 0 held)
//                 SEND: [25:16] source bus
//   words 1 and 3 (ADSR): linear rate coefficients kA/kD/kR and the
//                 sustain level — see the ADSR wire format in patch.h
//   word 2 DEPTH: [17:0] signed Q2.16 coefficient, 0x10000 = unity
// The producer ADDS to the bus base: firmware's base write and the
// producer's contribution coexist on one bus (e.g. bend + vibrato).
// Amp-envelope idiom (volume semantics): base = −span (the quiet
// floor), depth POSITIVE — the envelope adds volume.
#define ENGINE_NUM_INSTR 256   // instruction pool; all 256 entries
                                    // execute every sample
// CSP opcode = CFG[3:0], a BITMASK of enables rather than an enum:
//   bit 0 reads a source operand      bit 2 multiplies by DEPTH
//   bit 1 has persistent state        bit 3 accumulates onto the target
// An envelope is the instruction that watches a gate, so state+source means
// envelope and state alone means phase accumulator. These must match
// synth_pkg.sv's OPC_* exactly -- a stale value here is silent: the gateware
// decodes it as some other instruction rather than rejecting it.
#define CSP_OPC_OFF   0x0u
#define CSP_OPC_LFO   0xEu   // state + multiply + accumulate
#define CSP_OPC_ADSR  0xFu   // source (gate) + state + multiply + accumulate
#define CSP_OPC_MAC  0xDu   // source + multiply + accumulate

bool engine_link_imem_write(uint8_t entry, uint8_t word, uint32_t value);


#ifdef __cplusplus
}
#endif
