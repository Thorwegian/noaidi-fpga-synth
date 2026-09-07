// stress_test.h — synthetic MIDI flood for reproducing load crashes.
//
// Gated by CONFIG_NOAIDI_STRESS_TEST (off by default). When enabled,
// stress_test_start() spawns a task that publishes CC sweeps + note
// churn onto the event bus at a heavy MIDI rate for a fixed window,
// reproducing the "adjust over Bluetooth while playing" crash (#70)
// deterministically, with no external MIDI source.
#pragma once

void stress_test_start(void);
