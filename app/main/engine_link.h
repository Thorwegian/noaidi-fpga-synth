// engine_link.h — the single owner of the FPGA SPI link
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

typedef struct {
    uint8_t  elem;    // element index 0..255
    uint8_t  word;    // 0..3 (p0..p3)
    uint32_t value;
} engine_cmd_t;

// Mutes every element into the local image, writes both banks (two
// full-image writes with a swap between), and starts the 1 kHz tick
// task. Call after fpga_spi_init(). The boot image goes silent here.
// Bus pointers initialize to 0 (no modulation); the bus plan — which
// pointer targets which bus — is entirely voice_alloc's convention,
// pushed as ordinary PTRS0/PTRS1 commands at its init.
void engine_link_init(void);

// Queue one parameter write. Non-blocking: returns false (and counts
// the drop) if the queue is full — the tick will log it.
bool engine_link_send(const engine_cmd_t *cmd);

// Queue one live bus-base write (bus_architecture.md). Buses are not
// banked and need no swap: the write goes straight to the bus base
// register (0x0800 + bus) on the next tick. Value is signed Q8.10 in
// the low 18 bits. Bus 0 is hardwired zero and cannot be written.
bool engine_link_bus_write(uint16_t bus, uint32_t value_q810);

// ── Producer table (B4/B5) ──────────────────────────────────────────
// 128 producers x 3 words (stride 4) at 0x0100, banked like
// parameters (config is wiring): writes land in the shadow and take
// effect at the swap, with the same catch-up mirroring as the
// element image.
//   word 0 CFG:   [3:0] type (0 off, 1 LFO, 2 ADSR), [5:4] LFO shape
//                 (saw/pulse/tri/sine), [15:6] target bus,
//                 LFO:  [31:16] rate (UQ0.24 increment low bits:
//                       5.7 mHz steps, 375 Hz max)
//                 ADSR: [25:16] gate bus (level-sensitive: > 0 held)
//   word 1 RATES (ADSR): [7:0] attack, [15:8] decay, [23:16] release
//                 as 8-bit log2 rates (increment = (16+low4) << high4
//                 on the 22-bit level), [31:24] sustain fraction
//   word 2 DEPTH: [17:0] signed Q8.10 contribution amplitude
// The producer ADDS to the bus base: firmware's base write and the
// producer's contribution coexist on one bus (e.g. bend + vibrato).
// Amp-envelope idiom: base = full attenuation, depth NEGATIVE — the
// envelope subtracts silence.
#define ENGINE_NUM_PRODUCERS 128
bool engine_link_prod_write(uint8_t entry, uint8_t word, uint32_t value);

#ifdef __cplusplus
}
#endif
