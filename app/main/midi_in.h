// midi_in.h — MIDI input processes (UART1 = DIN, UART0 = panel)
//
// Two serial MIDI ingress ports, each 31250 baud 8N1 with its own
// parser instance, both publishing to the event bus.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Configure UART1 as the DIN MIDI input port and start its RX task.
//
// rx_pin — GPIO to use for MIDI RX (e.g. 0).
//
// NOTE: UART1's default TX pin is GPIO7 and default RX pin is GPIO6,
// which the SPI driver uses for CS and MOSI respectively. This call
// moves RX to rx_pin but leaves TX on the default pin, so fpga_spi_init()
// must run AFTER midi_in_init() so the SPI driver re-claims GPIO7.
void midi_in_init(int rx_pin);

// Configure UART0 as the dev-host panel MIDI port (#90) and start its
// RX task. Reserved for Open Stage Control exclusively (Thor,
// 2026-09-10). Requires the console to be off UART0 (it lives on the
// USB-Serial/JTAG controller since the same date).
//
// rx_pin — GPIO wired to the panel MIDI-IN circuit (e.g. 2).
void midi_panel_init(int rx_pin);

#ifdef __cplusplus
}
#endif
