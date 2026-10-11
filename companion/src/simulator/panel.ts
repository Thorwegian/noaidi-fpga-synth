// panel.ts — the simulated instrument's controls acting on the sound and
// the surface
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What a hardware panel's firmware would do with its knobs and buttons:
// a moved knob sets its parameter (through its panel range and taper) and
// focuses it; a turned encoder steps its current assignment; a button
// switches layer. React components call these and draw the results.
//
// Pure TypeScript: no React or native imports.

import { getValue } from '../core/patch';
import type { PatchStore } from '../core/patchStore';
import {
  assignmentFor, createSurfaceController, positionToValue, turnEncoder, valueToPosition,
  type Layout, type SurfaceController,
} from '../core/surface';

export interface Panel {
  readonly surface: SurfaceController;
  // A permanent control touched (no value change yet).
  touch(control: string): void;
  // A permanent control moved to position (0 … 1).
  move(control: string, position: number): void;
  // Where a permanent control sits for the current value.
  position(control: string): number;
  // An encoder turned by steps detents.
  turn(control: string, steps: number): void;
  press(button: string): void;
  tick(): void;
}

export function createPanel(layout: Layout, store: PatchStore, now: () => number = Date.now): Panel {
  const surface = createSurfaceController(layout, now());
  const control = (id: string) => surface.dispatch({ type: 'control', control: id, time: now() });

  return {
    surface,
    touch: control,

    move(id, position) {
      const a = assignmentFor(layout, surface.getState(), id);
      if (!a) return;
      store.set(a.param, positionToValue(a, position), { coalesce: true });
      control(id);
    },

    position(id) {
      const a = assignmentFor(layout, surface.getState(), id);
      return a ? valueToPosition(a, store.get(a.param) as number) : 0;
    },

    turn(id, steps) {
      const a = assignmentFor(layout, surface.getState(), id);
      if (!a) return;
      const next = turnEncoder(layout, store.getPatch(), a, steps);
      store.set(a.param, getValue(next, a.param), { coalesce: true });
      control(id);
    },

    press(button) {
      surface.dispatch({ type: 'button', control: button, time: now() });
    },

    tick() {
      surface.dispatch({ type: 'tick', time: now() });
    },
  };
}
