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
// - switching layer shows the layer overview (the new assignments); a
//   button shared by several layers steps through them;
// - after screen.focusTimeoutMs without activity, the screen returns to
//   the layer overview.
//
// Pure TypeScript: no React or native imports.

import { hasParameter, parameter, type NumberParameter, type ParameterId, type Range } from './parameters';
import { getValue, setValue, type Preset } from './preset';

export type ControlKind = 'knob' | 'fader' | 'encoder' | 'button';

export type Cell = readonly [column: number, row: number];

export interface Control {
  readonly id: string;
  readonly kind: ControlKind;
  readonly at: Cell;                  // top-left cell on the panel grid
  readonly span?: Cell;               // columns × rows; default 1 × 1
  readonly label?: string;
}

// How a control's travel maps onto the panel range: 'linear', 'exponential'
// (equal ratio per step; needs a positive range), 'square' (fine at the
// bottom) or 'bipolarSquare' (fine near the centre, coarse at the ends).
export type Taper = 'linear' | 'exponential' | 'square' | 'bipolarSquare';

export interface Assignment {
  readonly param: ParameterId;
  readonly range?: Range;      // panel range; default: the engine range
  // Panel range per value of the parameter this one depends on (an LFO's
  // depth per destination); falls back to range.
  readonly rangeBy?: Readonly<Record<string, Range>>;
  readonly taper?: Taper;      // default: defaultTaper()
  readonly detents?: number;   // an encoder's detents across the panel range
}

// A picture the display draws in a layer's overview.
export type Graphic = 'none' | 'filter' | 'ampEnv' | 'modEnv';

export interface Overview {
  readonly tiles: readonly ParameterId[];   // up to 4; two show over a picture
  readonly graphic: Graphic;
}

export interface Layer {
  readonly id: string;
  readonly label: string;
  // The button that selects it. Layers sharing a button take turns: each
  // press selects the next of them.
  readonly button: string;
  readonly assign: Readonly<Record<string, Assignment>>;   // encoder → assignment
  readonly overview?: Overview;
}

export interface ScreenConfig {
  readonly focusTimeoutMs: number;
}

// A labelled box drawn around a group of controls.
export interface PanelGroup {
  readonly label: string;
  readonly at: Cell;
  readonly span: Cell;
}

export interface Layout {
  readonly name: string;
  readonly hypothesis?: string;   // what this layout is meant to test
  readonly grid: { readonly columns: number; readonly rows: number };
  readonly display: { readonly at: Cell; readonly span: Cell };
  readonly groups?: readonly PanelGroup[];
  readonly controls: readonly Control[];
  readonly fixed: Readonly<Record<string, Assignment>>;   // permanent control → assignment
  readonly layers: readonly Layer[];
  readonly screen: ScreenConfig;
  readonly encoderStepsPerTravel: number;   // default detents across the panel range
}

export const MAX_OVERVIEW_TILES = 4;

function cells(at: Cell, span: Cell = [1, 1]): string[] {
  const out: string[] = [];
  for (let c = at[0]; c < at[0] + span[0]; c++)
    for (let r = at[1]; r < at[1] + span[1]; r++) out.push(`${c},${r}`);
  return out;
}

function within(inner: Range, outer: Range): boolean {
  return inner.min >= outer.min && inner.max <= outer.max && inner.min < inner.max;
}

// Problems with a layout: unknown parameters or controls, assignments on
// the wrong kind of control, panel ranges outside the engine's, controls
// off the grid or on top of each other.
export function validateLayout(layout: Layout): string[] {
  const errors: string[] = [];
  const controls = new Map(layout.controls.map((c) => [c.id, c]));

  const used = new Map<string, string>();
  const place = (what: string, at: Cell, span?: Cell) => {
    for (const cell of cells(at, span)) {
      const [c, r] = cell.split(',').map(Number) as [number, number];
      if (c < 0 || r < 0 || c >= layout.grid.columns || r >= layout.grid.rows)
        errors.push(`${what}: off the grid at ${cell}`);
      else if (used.has(cell)) errors.push(`${what}: overlaps ${used.get(cell)} at ${cell}`);
      else used.set(cell, what);
    }
  };
  place('display', layout.display.at, layout.display.span);
  for (const c of layout.controls) place(c.id, c.at, c.span);

  const check = (where: string, controlId: string, a: Assignment, kinds: ControlKind[]) => {
    const c = controls.get(controlId);
    if (!c) errors.push(`${where}: no control ${controlId}`);
    else if (!kinds.includes(c.kind)) errors.push(`${where}: ${controlId} is a ${c.kind}`);
    if (!hasParameter(a.param)) { errors.push(`${where}: no parameter ${a.param}`); return; }
    const p = parameter(a.param);
    if (p.kind === 'name') {
      if (a.range || a.rangeBy || a.taper) errors.push(`${where}: ${a.param} is a name parameter`);
      return;
    }
    if (a.range && !within(a.range, p.range))
      errors.push(`${where}: ${a.param} panel range outside the engine range`);
    for (const [value, range] of Object.entries(a.rangeBy ?? {})) {
      const spec = p.byValue?.[value];
      if (!spec) errors.push(`${where}: ${a.param} has no range for ${value}`);
      else if (!within(range, spec.range))
        errors.push(`${where}: ${a.param} panel range for ${value} outside the engine range`);
    }
    for (const range of [a.range, ...Object.values(a.rangeBy ?? {})])
      if (range && (a.taper ?? defaultTaper(p, range)) === 'exponential' && range.min <= 0)
        errors.push(`${where}: exponential taper needs a positive range`);
  };
  for (const [id, a] of Object.entries(layout.fixed)) check('fixed', id, a, ['knob', 'fader']);
  for (const layer of layout.layers) {
    if (controls.get(layer.button)?.kind !== 'button')
      errors.push(`layer ${layer.id}: ${layer.button} is not a button`);
    for (const [id, a] of Object.entries(layer.assign)) check(`layer ${layer.id}`, id, a, ['encoder']);
    for (const t of layer.overview?.tiles ?? [])
      if (!hasParameter(t)) errors.push(`layer ${layer.id}: no parameter ${t}`);
    if ((layer.overview?.tiles.length ?? 0) > MAX_OVERVIEW_TILES)
      errors.push(`layer ${layer.id}: more than ${MAX_OVERVIEW_TILES} overview tiles`);
  }
  for (const c of layout.controls)
    if ((c.kind === 'knob' || c.kind === 'fader') && !layout.fixed[c.id])
      errors.push(`${c.id}: a ${c.kind} with no assignment`);
  if (layout.layers.length === 0) errors.push('no layers');
  return errors;
}

// ── Tapers ──────────────────────────────────────────────────────────

// A starting heuristic only: ratio units (seconds, Hz, Q) get an
// exponential taper when their range is positive.
export function defaultTaper(p: NumberParameter, range: Range): Taper {
  return p.nearest === 'ratio' && range.min > 0 ? 'exponential' : 'linear';
}

// The panel range of an assignment; for one with rangeBy, given the
// preset's value of the parameter it depends on.
export function panelRange(a: Assignment, preset?: Preset): Range {
  const p = parameter(a.param);
  if (p.kind !== 'number') throw new RangeError(`${a.param} is not a number parameter`);
  if (a.rangeBy && preset && p.dependsOn) {
    const r = a.rangeBy[String(getValue(preset, p.dependsOn))];
    if (r) return r;
  }
  return a.range ?? p.range;
}

function taperOf(a: Assignment, range: Range): Taper {
  return a.taper ?? defaultTaper(parameter(a.param) as NumberParameter, range);
}

const clamp01 = (x: number) => Math.min(Math.max(x, 0), 1);

// Control position (0 … 1) → value in the panel range.
export function positionToValue(a: Assignment, position: number, preset?: Preset): number {
  const range = panelRange(a, preset);
  const { min, max } = range;
  const x = clamp01(position);
  switch (taperOf(a, range)) {
    case 'exponential': return min * Math.pow(max / min, x);
    case 'square': return min + x * x * (max - min);
    case 'bipolarSquare': {
      const s = 2 * x - 1;
      return (min + max) / 2 + Math.sign(s) * s * s * (max - min) / 2;
    }
    default: return min + x * (max - min);
  }
}

// Value → control position (0 … 1); values outside the panel range sit at
// the ends.
export function valueToPosition(a: Assignment, value: number, preset?: Preset): number {
  const range = panelRange(a, preset);
  const { min, max } = range;
  if (max === min) return 0;
  switch (taperOf(a, range)) {
    case 'exponential':
      return value > 0 ? clamp01(Math.log(value / min) / Math.log(max / min)) : 0;
    case 'square':
      return Math.sqrt(clamp01((value - min) / (max - min)));
    case 'bipolarSquare': {
      const s = (2 * value - (min + max)) / (max - min);
      return clamp01((Math.sign(s) * Math.sqrt(Math.min(Math.abs(s), 1)) + 1) / 2);
    }
    default: return clamp01((value - min) / (max - min));
  }
}

// The preset after an encoder turns steps detents: a name parameter steps
// through its names, a number parameter moves steps / detents of its panel
// travel (the assignment's detents, or the layout's).
export function turnEncoder(layout: Layout, preset: Preset, a: Assignment, steps: number): Preset {
  const p = parameter(a.param);
  const current = getValue(preset, a.param);
  if (p.kind === 'name') {
    const i = p.names.indexOf(current as string);
    const next = Math.min(Math.max(i + steps, 0), p.names.length - 1);
    return setValue(preset, a.param, p.names[next]);
  }
  const detents = a.detents ?? layout.encoderStepsPerTravel;
  const pos = valueToPosition(a, current as number, preset) + steps / detents;
  return setValue(preset, a.param, positionToValue(a, pos, preset));
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

export function layerOf(layout: Layout, state: SurfaceState): Layer {
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
      const sharing = layout.layers.filter((l) => l.button === event.control);
      if (sharing.length === 0) return state;
      const current = sharing.findIndex((l) => l.id === state.layerId);
      const layer = sharing[(current + 1) % sharing.length]!;   // first, or the next
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
