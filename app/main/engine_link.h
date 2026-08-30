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
#define ENGINE_WORDS_PER_ELEMENT 4   // p0 OSC, p1 DUTY, p2 FILTER, p3 GAIN

typedef struct {
    uint8_t  elem;    // element index 0..255
    uint8_t  word;    // 0..3 (p0..p3)
    uint32_t value;
} engine_cmd_t;

// Mutes every element into the local image, writes both banks (two
// full-image writes with a swap between), and starts the 1 kHz tick
// task. Call after fpga_spi_init(). The boot image goes silent here.
void engine_link_init(void);

// Queue one parameter write. Non-blocking: returns false (and counts
// the drop) if the queue is full — the tick will log it.
bool engine_link_send(const engine_cmd_t *cmd);

#ifdef __cplusplus
}
#endif
