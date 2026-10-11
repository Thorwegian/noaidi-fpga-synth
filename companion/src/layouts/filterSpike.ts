// filterSpike.ts — the smallest panel: the controls of the LVGL/WASM spike
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A UX hypothesis for testing the architecture, not a panel design.
// Panel ranges seed from the MIDI CC reach: cutoff over the audible range,
// resonance up to CC 71's Q 32.

import type { Layout } from '../core/surface';

export const filterSpike: Layout = {
  name: 'Filter spike',
  hypothesis: 'A virtual knob reaches the real LVGL display, focus follows the hand',
  controls: [
    { id: 'cutoff', kind: 'knob', at: [0, 0], label: 'Cutoff' },
    { id: 'resonance', kind: 'knob', at: [1, 0], label: 'Resonance' },
    { id: 'e1', kind: 'encoder', at: [0, 1] },
    { id: 'e2', kind: 'encoder', at: [1, 1] },
    { id: 'e3', kind: 'encoder', at: [2, 1] },
    { id: 'e4', kind: 'encoder', at: [3, 1] },
    { id: 'bFilter', kind: 'button', at: [0, 2], label: 'FILTER' },
  ],
  fixed: {
    cutoff: { param: 'filter.cutoff', range: { min: 20, max: 14388.3 } },
    resonance: { param: 'filter.resonance', range: { min: 0.707107, max: 32 } },
  },
  layers: [
    {
      id: 'filter', label: 'FILTER', button: 'bFilter',
      assign: {
        e1: { param: 'filter.type' },
        e2: { param: 'filter.slope' },
        e3: { param: 'filter.key_track' },
      },
    },
  ],
  screen: { focusTimeoutMs: 2000 },
  encoderStepsPerTravel: 64,
};
