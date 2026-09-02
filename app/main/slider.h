// slider.h — panel slider (10k linear pot) on GPIO1/A1 → resonance
//
// The wiper feeds ADC1 channel 1 through a divider (680R to GND,
// 3k6 to 3.3V around the pot) that keeps the voltage inside the
// max-attenuation ADC range. Readings map through a stored
// calibration (min/max raw counts, persisted in NVS — the ESP32-C3
// has no EEPROM; NVS-in-flash is the platform equivalent) to an
// internal MIDI CC 71 event on the event bus, so the slider IS the
// resonance knob (voice_alloc's temporary CC 71 handler does the
// rest; when the MIDI schema lands, only the CC number moves).
//
// Serial-monitor keys (USB-Serial-JTAG console):
//   c  toggle calibration: first press starts capturing min/max
//      while you run the slider end to end (raw values print live),
//      second press saves to NVS and adopts the new range
//   r  print one raw reading + the active calibration

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Starts the ADC poll task and the console key task. Call after
// voice_alloc_init() (events published before subscribers exist are
// harmlessly dropped, but why waste them).
void slider_init(void);

#ifdef __cplusplus
}
#endif
