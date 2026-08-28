// spi_regs.h — ESP32-C3 driver for spi_slave_regs FPGA peripheral
//
// Protocol summary:
//   Byte 0:  [7]=R/W (1=read, 0=write), [6:0]=7-bit register address
//   Byte 1+: data bytes, address auto-increments after each byte
//
//   Write: 2+N bytes (cmd + N data bytes)
//   Read:  2+N bytes (cmd + 1 dummy + N data bytes)
//          The first response byte is the dummy; register data starts
//          at byte 1 (mem[addr] is combinational, auto-increments).
//
// SPI Mode 0 (CPOL=0, CPHA=0), MSB-first, up to ~20 MHz.

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

// ── Single-register operations ──────────────────────────────────────

// Write one byte to a register
void fpga_reg_write(uint8_t addr, uint8_t data);

// Read one byte from a register
uint8_t fpga_reg_read(uint8_t addr);

// ── Multi-register (burst) operations ───────────────────────────────
// addr = starting register, data = buffer, len = number of registers

// Write len bytes starting at addr
void fpga_reg_write_burst(uint8_t addr, const uint8_t *data, size_t len);

// Read len bytes starting at addr into buf.
// Internally reads len+1 bytes and discards the first 1.
void fpga_reg_read_burst(uint8_t addr, uint8_t *buf, size_t len);

// Diagnostic: send 5 bytes, print the raw MISO bytes returned.
void fpga_raw_loopback(void);

#ifdef __cplusplus
}
#endif
