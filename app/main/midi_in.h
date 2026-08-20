// midi_in.h — MIDI input process (UART1)
//
// Bring-up stage: receives serial bytes at 31250 baud 8N1 and logs
// each one to the console as hex. MIDI parsing, note allocation and
// a command queue toward the SPI process come later.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Configure UART1 as the MIDI input port and start its RX task.
//
// rx_pin — GPIO to use for MIDI RX (e.g. 0).
//
// NOTE: UART1's default TX pin is GPIO7 and default RX pin is GPIO6,
// which the SPI driver uses for CS and MOSI respectively. This call
// moves RX to rx_pin but leaves TX on the default pin, so fpga_spi_init()
// must run AFTER midi_in_init() so the SPI driver re-claims GPIO7.
void midi_in_init(int rx_pin);

#ifdef __cplusplus
}
#endif
