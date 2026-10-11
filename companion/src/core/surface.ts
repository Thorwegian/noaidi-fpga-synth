// surface.ts — the control-surface model: physical controls, what they
// are assigned to, and what the screen shows
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A Layout is data, so trying another panel means loading another layout.
// It names the physical controls (knobs, faders, endless encoders,
// buttons), the permanent assignments, and layers of assignments for the
// encoders, chosen with buttons. An assignment carries the PANEL range and
// taper: a UX choice, separate from the engine's range (the manifest) and
// from any transport's reach (MIDI CC).
//
// The focus rules are a pure function of events, so the hardware panel
// can copy them:
// - touching or moving a permanent control focuses its parameter;
// - turning an encoder focuses the parameter it has on the current layer;
// - tapping a parameter on the screen focuses it;
// - switching layer shows the layer overview (the new assignments);
// - after screen.focusTimeoutMs without activity, the screen returns to
//   the layer overview.
//
// Pure TypeScript: no React or native imports.

import { hasParameter, parameter, type NumberParameter, type ParameterId, type Range } from './parameters';
import { getValue, setValue, type Patch } from './patch';

export type ControlKind = 'knob' | 'fader' | 'encoder' | 'button';

export interface Control {
  readonly id: string;
  readonly kind: ControlKind;
  readonly at: readonly [column: number, row: number];   // grid position on the panel
  readonly label?: string;
}

// How a control's travel maps onto the panel range: 'linear', 'exponential'
// (equal ratio per step; needs a positive range) or 'bipolarSquare' (fine
// near the centre, coarse at the ends).
export type Taper = 'linear' | 'exponential' | 'bipolarSquare';

export interface Assignment {
  readonly param: ParameterId;
  readonly range?: Range;      // panel range; default: the engine range
  readonly taper?: Taper;      // default: defaultTaper()
}

export interface Layer {
  readonly id: string;
  readonly label: string;
  readonly button: string;                              // control that selects it
  readonly assign: Readonly<Record<string, Assignment>>;   // encoder → assignment
}

export interface ScreenConfig {
  readonly focusTimeoutMs: number;
}

export interface Layout {
  readonly name: string;
  readonly hypothesis?: string;   // what this layout is meant to test
  readonly controls: readonly Control[];
  readonly fixed: Readonly<Record<string, Assignment>>;   // permanent control → assignment
  readonly layers: readonly Layer[];
  readonly screen: ScreenConfig;
  readonly encoderStepsPerTravel: number;   // encoder detents across the full panel range
}

// Problems with a layout: unknown parameters or controls, assignments on
// the wrong kind of control.
export function validateLayout(layout: Layout): string[] {
  const errors: string[] = [];
  const controls = new Map(layout.controls.map((c) => [c.id, c]));
  const check = (where: string, controlId: string, a: Assignment, kinds: ControlKind[]) => {
    const c = controls.get(controlId);
    if (!c) errors.push(`${where}: no control ${controlId}`);
    else if (!kinds.includes(c.kind)) errors.push(`${where}: ${controlId} is a ${c.kind}`);
    if (!hasParameter(a.param)) errors.push(`${where}: no parameter ${a.param}`);
    else if (a.taper === 'exponential' && panelRange(a).min <= 0)
      errors.push(`${where}: exponential taper needs a positive range`);
  };
  for (const [id, a] of Object.entries(layout.fixed)) check('fixed', id, a, ['knob', 'fader']);
  for (const layer of layout.layers) {
    if (controls.get(layer.button)?.kind !== 'button')
      errors.push(`layer ${layer.id}: ${layer.button} is not a button`);
    for (const [id, a] of Object.entries(layer.assign)) check(`layer ${layer.id}`, id, a, ['encoder']);
  }
  if (layout.layers.length === 0) errors.push('no layers');
  return errors;
}

// ── Tapers ──────────────────────────────────────────────────────────

// A starting heuristic only: ratio units (seconds, Hz, Q) get an
// exponential taper when their range is positive.
export function defaultTaper(p: NumberParameter, range: Range): Taper {
  return p.nearest === 'ratio' && range.min > 0 ? 'exponential' : 'linear';
}

function panelRange(a: Assignment): Range {
  const p = parameter(a.param);
  if (p.kind !== 'number') throw new RangeError(`${a.param} is not a number parameter`);
  return a.range ?? p.range;
}

function taperOf(a: Assignment): Taper {
  return a.taper ?? defaultTaper(parameter(a.param) as NumberParameter, panelRange(a));
}

const clamp01 = (x: number) => Math.min(Math.max(x, 0), 1);

// Control position (0 … 1) → value in the panel range.
export function positionToValue(a: Assignment, position: number): number {
  const { min, max } = panelRange(a);
  const x = clamp01(position);
  switch (taperOf(a)) {
    case 'exponential': return min * Math.pow(max / min, x);
    case 'bipolarSquare': {
      const s = 2 * x - 1;
      return (min + max) / 2 + Math.sign(s) * s * s * (max - min) / 2;
    }
    default: return min + x * (max - min);
  }
}

// Value → control position (0 … 1); values outside the panel range sit at
// the ends.
export function valueToPosition(a: Assignment, value: number): number {
  const { min, max } = panelRange(a);
  if (max === min) return 0;
  switch (taperOf(a)) {
    case 'exponential':
      return value > 0 ? clamp01(Math.log(value / min) / Math.log(max / min)) : 0;
    case 'bipolarSquare': {
      const s = (2 * value - (min + max)) / (max - min);
      return clamp01((Math.sign(s) * Math.sqrt(Math.min(Math.abs(s), 1)) + 1) / 2);
    }
    default: return clamp01((value - min) / (max - min));
  }
}

// The patch after an encoder turns steps detents: a name parameter steps
// through its names, a number parameter moves steps/encoderStepsPerTravel
// of its panel travel.
export function turnEncoder(layout: Layout, patch: Patch, a: Assignment, steps: number): Patch {
  const p = parameter(a.param);
  const current = getValue(patch, a.param);
  if (p.kind === 'name') {
    const i = p.names.indexOf(current as string);
    const next = Math.min(Math.max(i + steps, 0), p.names.length - 1);
    return setValue(patch, a.param, p.names[next]);
  }
  const pos = valueToPosition(a, current as number) + steps / layout.encoderStepsPerTravel;
  return setValue(patch, a.param, positionToValue(a, pos));
}

// ── Focus and screen ────────────────────────────────────────────────

// The control of a focus that came from tapping the screen.
export const SCREEN = 'screen';

export interface Focus {
  readonly control: string;   // a control's id, or SCREEN
  readonly param: ParameterId;
}

export interface SurfaceState {
  readonly layerId: string;
  readonly focus: Focus | null;
  readonly lastActivity: number;   // ms
}

export type SurfaceEvent =
  | { readonly type: 'control'; readonly control: string; readonly time: number }   // touched, moved or turned
  | { readonly type: 'button'; readonly control: string; readonly time: number }
  | { readonly type: 'screen'; readonly param: ParameterId; readonly time: number }   // tapped on the screen
  | { readonly type: 'tick'; readonly time: number };

export type ScreenView =
  | { readonly mode: 'parameter'; readonly focus: Focus; readonly layer: Layer }
  | { readonly mode: 'layer'; readonly layer: Layer };

export function initialSurfaceState(layout: Layout, time = 0): SurfaceState {
  return { layerId: layout.layers[0]!.id, focus: null, lastActivity: time };
}

function layerOf(layout: Layout, state: SurfaceState): Layer {
  return layout.layers.find((l) => l.id === state.layerId) ?? layout.layers[0]!;
}

// What control is assigned to right now: its permanent assignment, or
// the current layer's.
export function assignmentFor(layout: Layout, state: SurfaceState, control: string): Assignment | undefined {
  return layout.fixed[control] ?? layerOf(layout, state).assign[control];
}

export function reduceSurface(layout: Layout, state: SurfaceState, event: SurfaceEvent): SurfaceState {
  switch (event.type) {
    case 'control': {
      const a = assignmentFor(layout, state, event.control);
      if (!a) return state;
      return { ...state, focus: { control: event.control, param: a.param }, lastActivity: event.time };
    }
    case 'screen':
      if (!hasParameter(event.param)) return state;
      return { ...state, focus: { control: SCREEN, param: event.param }, lastActivity: event.time };
    case 'button': {
      const layer = layout.layers.find((l) => l.button === event.control);
      if (!layer) return state;
      return { layerId: layer.id, focus: null, lastActivity: event.time };
    }
    case 'tick':
      if (state.focus && event.time - state.lastActivity >= layout.screen.focusTimeoutMs)
        return { ...state, focus: null };
      return state;
  }
}

export function screenView(layout: Layout, state: SurfaceState): ScreenView {
  const layer = layerOf(layout, state);
  return state.focus ? { mode: 'parameter', focus: state.focus, layer } : { mode: 'layer', layer };
}

// ── Controller ──────────────────────────────────────────────────────

export type SurfaceListener = (state: SurfaceState) => void;

export interface SurfaceController {
  readonly layout: Layout;
  getState(): SurfaceState;
  dispatch(event: SurfaceEvent): void;
  subscribe(listener: SurfaceListener): () => void;
}

// Holds the surface state and tells listeners when it changes. The caller
// sends 'tick' events (every 100 ms or so) for the focus timeout.
export function createSurfaceController(layout: Layout, time = 0): SurfaceController {
  let state = initialSurfaceState(layout, time);
  const listeners = new Set<SurfaceListener>();
  return {
    layout,
    getState: () => state,
    dispatch(event) {
      const next = reduceSurface(layout, state, event);
      if (next === state) return;
      const visible = next.layerId !== state.layerId || next.focus?.param !== state.focus?.param
        || next.focus?.control !== state.focus?.control;
      state = next;
      if (visible) for (const l of listeners) l(state);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
