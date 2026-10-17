// spi_regs.h — ESP32-C3 driver for the FPGA's spi_bus peripheral
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB-first; measured clean to 40 MHz.

#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── Initialisation ──────────────────────────────────────────────────
// Call once at startup.  Configures SPI2 (HSPI) as master.
//   mosi_pin, miso_pin, sclk_pin, cs_pin — GPIO numbers
//   freq_hz — SPI clock (e.g. 10000000 for 10 MHz)
void fpga_spi_init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin,
                   uint32_t freq_hz);

// ── Word protocol (spi_bus.sv / docs/memory_map.md) ─────────────────
// 16-bit word addresses, 32-bit data, MSB first on the wire.
#include <stdbool.h>
void fpga_word_write(uint16_t addr, uint32_t value);
void fpga_word_write_burst(uint16_t addr, const uint32_t *words, size_t n);
uint32_t fpga_word_read(uint16_t addr);
bool fpga_word_read_burst(uint16_t addr, uint32_t *words, size_t n);

#ifdef __cplusplus
}
#endif
