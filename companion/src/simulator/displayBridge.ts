// displayBridge.ts — keeps the LVGL display (WebAssembly in a WebView or
// iframe) in step with the sound and the surface
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The simulator's half of display/ports/web/shell.js's JSON messages. It
// is the simulated stand-in for what the hardware panel's firmware will
// do with direct C calls (noaidi_display_set_value() and friends); it is
// not part of the instrument's architecture.
//
// A parameter goes over as its index in the manifest, which is its
// noaidi_param_t in display/include/noaidi_param_ids.h (both generated
// by tools/gen_manifest).
//
// Pure TypeScript: no React or native imports.

import type { Patch } from '../core/patch';
import type { PatchStore } from '../core/patchStore';
import { parameter, parameters, type ParameterId } from '../core/parameters';
import { assignmentFor, type SurfaceController } from '../core/surface';

export const NONE = -1;
export const ENCODERS = 4;

export type ToDisplay =
  | { readonly type: 'value'; readonly param: number; readonly value: number | 'inf' | '-inf' }
  | { readonly type: 'name'; readonly param: number; readonly name: string }
  | { readonly type: 'focus'; readonly param: number }
  | { readonly type: 'layer'; readonly label: string; readonly assign: readonly number[] };

export type FromDisplay =
  | { readonly type: 'ready'; readonly width: number; readonly height: number }
  | { readonly type: 'touched'; readonly param: number }
  | { readonly type: 'fps'; readonly fps: number };

const indexOf = new Map(parameters.map((p, i) => [p.id, i]));

export function paramIndex(id: ParameterId): number {
  const i = indexOf.get(id);
  if (i === undefined) throw new RangeError(`unknown parameter ${id}`);
  return i;
}

export function paramAt(index: number): ParameterId | undefined {
  return parameters[index]?.id;
}

export function valueMessage(patch: Patch, id: ParameterId): ToDisplay {
  const v = patch.values[id]!;
  const param = paramIndex(id);
  if (parameter(id).kind === 'name') return { type: 'name', param, name: v as string };
  const n = v as number;
  return { type: 'value', param, value: n === Infinity ? 'inf' : n === -Infinity ? '-inf' : n };
}

// The encoder controls in panel order: what the display's four encoder
// slots stand for.
function encoderIds(surface: SurfaceController): string[] {
  return surface.layout.controls.filter((c) => c.kind === 'encoder').map((c) => c.id).slice(0, ENCODERS);
}

export function layerMessage(surface: SurfaceController): ToDisplay {
  const state = surface.getState();
  const layer = surface.layout.layers.find((l) => l.id === state.layerId)!;
  const assign = encoderIds(surface).map((id) => {
    const a = assignmentFor(surface.layout, state, id);
    return a ? paramIndex(a.param) : NONE;
  });
  while (assign.length < ENCODERS) assign.push(NONE);
  return { type: 'layer', label: layer.label, assign };
}

export function focusMessage(surface: SurfaceController): ToDisplay {
  const focus = surface.getState().focus;
  return { type: 'focus', param: focus ? paramIndex(focus.param) : NONE };
}

// Everything the display shows, for a display that just started.
export function fullState(store: PatchStore, surface: SurfaceController): ToDisplay[] {
  const patch = store.getPatch();
  return [
    ...parameters.map((p) => valueMessage(patch, p.id)),
    layerMessage(surface),
    focusMessage(surface),
  ];
}

export interface DisplayBridge {
  // A message from the display.
  receive(message: FromDisplay): void;
  dispose(): void;
}

// Send the display every change from now on, and the full state whenever
// it reports ready. A tap on the screen focuses that parameter.
export function connectDisplay(store: PatchStore, surface: SurfaceController,
                               send: (message: ToDisplay) => void,
                               now: () => number = Date.now): DisplayBridge {
  let lastLayer = surface.getState().layerId;
  const offStore = store.subscribe((patch, changed) => {
    for (const id of changed) send(valueMessage(patch, id));
  });
  const offSurface = surface.subscribe((state) => {
    if (state.layerId !== lastLayer) {
      lastLayer = state.layerId;
      send(layerMessage(surface));
    }
    send(focusMessage(surface));
  });
  return {
    receive(message) {
      if (message.type === 'ready') fullState(store, surface).forEach(send);
      if (message.type === 'touched') {
        const id = paramAt(message.param);
        if (id) surface.dispatch({ type: 'screen', param: id, time: now() });
      }
    },
    dispose() {
      offStore();
      offSurface();
    },
  };
}
