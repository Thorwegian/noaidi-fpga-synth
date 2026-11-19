// midi_in.h — MIDI input processes (UART1 = din1, UART2 = din2)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Two serial MIDI ingress ports, the DIN inputs din1 and din2, each
// 31250 baud 8N1 with its own parser instance, both publishing to the
// event bus.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Configure UART1 as din1, the first DIN input. Its RX task starts with
// midi_in_start().
//
// rx_pin — GPIO wired to the first optocoupler's output (18 on the base
// board). TX is left unrouted.
void midi_din1_init(int rx_pin);

// Configure UART2 as din2, the second DIN input. Its RX task starts with
// midi_in_start(). The line's idle level is sampled first and RX is
// inverted, with a warning, when it idles low.
//
// rx_pin — GPIO wired to the second optocoupler's output (1 on the base
// board). TX is left unrouted.
void midi_din2_init(int rx_pin);

// Start the RX tasks of the configured ports, so they begin publishing
// to the event bus. Call after every event-bus subscriber has registered.
void midi_in_start(void);

#ifdef __cplusplus
}
#endif
