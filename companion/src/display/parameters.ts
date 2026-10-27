// parameters.ts — how each parameter is shown: label, section, unit,
// formatting, and how a player interacts with it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The companion owns this; the engine's facts (range, values, init
// value) come from the manifest. Every generated parameter ID must have
// an entry here, and every entry a parameter (test/display.test.ts), so
// a new synth parameter fails `make check` until it is given one.
//
// Interaction is a UX statement, not a consequence of the engine: an
// envelope time has 232 distinct engine values but is played as a
// continuous control; a waveform is a genuine choice. Panel placement,
// panel range and taper are not here: they belong to each panel layout.
//
// Pure TypeScript: no React or native imports.

import { parameter, parameters, type ParameterId, type Value } from '../core/parameters';
import type { Preset } from '../core/preset';

// How a player changes it.
export type Interaction =
  | 'continuous'   // a sweep: knob, fader, slider
  | 'choice'       // one of a few named options
  | 'toggle'       // one of two options
  | 'stepped';     // a count of whole units

// The full Editor's control for it.
export type EditorControl = 'slider' | 'segmented' | 'select' | 'toggle' | 'stepper';

export interface ParameterDisplay {
  readonly id: ParameterId;
  readonly label: string;        // stands alone: "Osc 1 tune"
  readonly shortLabel: string;   // within its section: "Tune"
  readonly section: string;      // "Osc 1", "Filter", ...
  readonly unit: string;         // "Hz", "s", "dB", "%", "st", "" ...
  readonly interaction: Interaction;
  readonly editor: EditorControl;
  readonly choiceLabels?: Readonly<Record<string, string>>;   // name → label
  format(value: Value): string;  // value with its unit
}

// ── Formatting ──────────────────────────────────────────────────────

const MINUS = '−';

function signed(v: number, decimals: number): string {
  const s = Math.abs(v).toFixed(decimals);
  return Number(s) === 0 ? s : (v < 0 ? MINUS : '+') + s;
}

function hz(v: number): string {
  if (v >= 1000) return `${(v / 1000).toFixed(v >= 10000 ? 1 : 2)} kHz`;
  if (v >= 100) return `${v.toFixed(0)} Hz`;
  if (v >= 10) return `${v.toFixed(1)} Hz`;
  if (v >= 1) return `${v.toFixed(2)} Hz`;
  return `${Number(v.toPrecision(2))} Hz`;
}

function seconds(v: number): string {
  if (v < 0.01) return `${(v * 1000).toFixed(2)} ms`;
  if (v < 0.1) return `${(v * 1000).toFixed(1)} ms`;
  if (v < 1) return `${(v * 1000).toFixed(0)} ms`;
  if (v < 10) return `${v.toFixed(2)} s`;
  return `${v.toFixed(1)} s`;
}

const num = (v: Value) => v as number;

// ── Entries ─────────────────────────────────────────────────────────

const WAVES = { saw: 'Saw', pulse: 'Pulse', triangle: 'Triangle', sine: 'Sine' };

const LFO_DEPTH_UNIT: Record<string, string> = {
  pulse_width: 'pts', resonance: 'oct', pitch: 'st', cutoff: 'st',
};

interface Entry {
  readonly label: (n: number) => string;
  readonly shortLabel: string;
  readonly section: (n: number) => string;
  readonly unit: string | ((preset: Preset | undefined, index: number) => string);
  readonly interaction: Interaction;
  readonly editor: EditorControl;
  readonly choiceLabels?: Readonly<Record<string, string>>;
  readonly format: (v: Value, unit: string) => string;
}

const choice = (v: Value, labels: Record<string, string>) => labels[v as string] ?? String(v);

function entry(section: (n: number) => string, shortLabel: string,
               rest: Omit<Entry, 'label' | 'section' | 'shortLabel'>): Entry {
  return { label: (n) => `${section(n)} ${shortLabel.toLowerCase()}`, shortLabel, section, ...rest };
}

const voice = () => 'Voice';
const osc = (n: number) => `Osc ${n + 1}`;
const filter = () => 'Filter';
const ampEnv = () => 'Amp envelope';
const modEnv = () => 'Mod envelope';
const lfo = (n: number) => `LFO ${n + 1}`;
const part = () => 'Part';

const STRUCTURES = { '1+1': '1 + 1', '7+1': '7 + 1 unison', '4+4': '4 + 4 unison' };
const FILTER_TYPES = { lowpass: 'Low-pass', bandpass: 'Band-pass', highpass: 'High-pass' };
const LFO_DESTINATIONS = { pulse_width: 'Pulse width', resonance: 'Resonance', pitch: 'Pitch', cutoff: 'Cutoff' };
const MOD_DESTINATIONS = { cutoff: 'Cutoff' };

const time = (section: () => string, label: string) => entry(section, label, {
  unit: 's', interaction: 'continuous', editor: 'slider', format: (v) => seconds(num(v)),
});
const percent = (section: () => string, label: string) => entry(section, label, {
  unit: '%', interaction: 'continuous', editor: 'slider', format: (v) => `${num(v).toFixed(0)} %`,
});

// Keyed by table.key; array elements share an entry.
const ENTRIES: Readonly<Record<string, Entry>> = {
  'voice.structure': entry(voice, 'Structure', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: STRUCTURES,
    format: (v) => choice(v, STRUCTURES),
  }),
  'voice.osc_mix': entry(voice, 'Osc mix', {
    unit: '%', interaction: 'continuous', editor: 'slider',
    format: (v) => num(v) <= -100 ? 'Osc 1 only' : num(v) >= 100 ? 'Osc 2 only' : `${signed(num(v), 0)} %`,
  }),
  'voice.unison_detune': entry(voice, 'Unison detune', {
    unit: 'st', interaction: 'continuous', editor: 'slider',
    format: (v) => `${num(v).toFixed(3)} st`,
  }),
  'voice.unison_stereo': percent(voice, 'Unison stereo'),

  'osc.wave': entry(osc, 'Wave', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: WAVES,
    format: (v) => choice(v, WAVES),
  }),
  'osc.tune': entry(osc, 'Tune', {
    unit: 'st', interaction: 'continuous', editor: 'slider',
    format: (v) => `${signed(num(v), Number.isInteger(num(v)) ? 0 : 2)} st`,
  }),
  'osc.pulse_width': entry(osc, 'Pulse width', {
    unit: '%', interaction: 'continuous', editor: 'slider', format: (v) => `${num(v).toFixed(1)} %`,
  }),

  'filter.type': entry(filter, 'Type', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: FILTER_TYPES,
    format: (v) => choice(v, FILTER_TYPES),
  }),
  'filter.slope': entry(filter, 'Slope', {
    unit: 'dB/oct', interaction: 'toggle', editor: 'segmented', format: (v) => `${num(v)} dB/oct`,
  }),
  'filter.cutoff': entry(filter, 'Cutoff', {
    unit: 'Hz', interaction: 'continuous', editor: 'slider', format: (v) => hz(num(v)),
  }),
  'filter.resonance': entry(filter, 'Resonance', {
    unit: 'Q', interaction: 'continuous', editor: 'slider',
    format: (v) => num(v) === Infinity ? 'Self-oscillating' : `Q ${num(v).toFixed(2)}`,
  }),
  'filter.key_track': percent(filter, 'Key tracking'),

  'amp_env.attack': time(ampEnv, 'Attack'),
  'amp_env.sustain': entry(ampEnv, 'Sustain', {
    unit: 'dB', interaction: 'continuous', editor: 'slider', format: (v) => `${signed(num(v), 1)} dB`,
  }),
  'amp_env.decay': time(ampEnv, 'Decay'),
  'amp_env.release': time(ampEnv, 'Release'),
  'amp_env.velocity': percent(ampEnv, 'Velocity'),

  'mod_env.attack': time(modEnv, 'Attack'),
  'mod_env.sustain': percent(modEnv, 'Sustain'),
  'mod_env.decay': time(modEnv, 'Decay'),
  'mod_env.release': time(modEnv, 'Release'),
  'mod_env.velocity': percent(modEnv, 'Velocity'),
  'mod_env.destination': entry(modEnv, 'Destination', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: MOD_DESTINATIONS,
    format: (v) => choice(v, MOD_DESTINATIONS),
  }),
  'mod_env.depth': entry(modEnv, 'Depth', {
    unit: 'st', interaction: 'continuous', editor: 'slider', format: (v) => `${signed(num(v), 1)} st`,
  }),

  'lfo.shape': entry(lfo, 'Shape', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: WAVES,
    format: (v) => choice(v, WAVES),
  }),
  'lfo.rate': entry(lfo, 'Rate', {
    unit: 'Hz', interaction: 'continuous', editor: 'slider', format: (v) => hz(num(v)),
  }),
  'lfo.destination': entry(lfo, 'Destination', {
    unit: '', interaction: 'choice', editor: 'segmented', choiceLabels: LFO_DESTINATIONS,
    format: (v) => choice(v, LFO_DESTINATIONS),
  }),
  'lfo.depth': entry(lfo, 'Depth', {
    // the destination's unit: percentage points of pulse width, octaves of
    // Q, semitones of pitch or cutoff
    unit: (preset, i) => LFO_DEPTH_UNIT[String(preset?.values[`lfo[${i}].destination`])] ?? '',
    interaction: 'continuous', editor: 'slider',
    format: (v, unit) => `${signed(num(v), unit === 'pts' ? 1 : 2)} ${unit}`.trimEnd(),
  }),

  'part.volume': entry(part, 'Volume', {
    unit: 'dB', interaction: 'continuous', editor: 'slider',
    format: (v) => num(v) === -Infinity ? 'Off' : `${signed(num(v), 1)} dB`,
  }),
  'part.pan': entry(part, 'Pan', {
    unit: '%', interaction: 'continuous', editor: 'slider',
    format: (v) => num(v) === 0 ? 'Centre' : `${num(v) < 0 ? 'L' : 'R'} ${Math.abs(num(v)).toFixed(0)} %`,
  }),
  'part.bend_range': entry(part, 'Bend range', {
    unit: 'st', interaction: 'stepped', editor: 'stepper', format: (v) => `±${num(v)} st`,
  }),
};

function entryKey(id: ParameterId): string {
  const p = parameter(id);
  return `${p.file.table}.${p.file.key}`;
}

// How parameter id is shown. A unit that depends on another parameter (an
// LFO's depth on its destination) is read from preset.
export function display(id: ParameterId, preset?: Preset): ParameterDisplay {
  const e = ENTRIES[entryKey(id)];
  if (!e) throw new RangeError(`no display entry for ${id}`);
  const n = parameter(id).file.index ?? 0;
  const unit = typeof e.unit === 'function' ? e.unit(preset, n) : e.unit;
  return {
    id,
    label: e.label(n),
    shortLabel: e.shortLabel,
    section: e.section(n),
    unit,
    interaction: e.interaction,
    editor: e.editor,
    choiceLabels: e.choiceLabels,
    format: (v) => e.format(v, unit),
  };
}

// Parameters without an entry, and entries without a parameter.
export function displayCoverage(): { missing: ParameterId[]; unused: string[] } {
  const used = new Set(parameters.map((p) => entryKey(p.id)));
  return {
    missing: parameters.filter((p) => !ENTRIES[entryKey(p.id)]).map((p) => p.id),
    unused: Object.keys(ENTRIES).filter((k) => !used.has(k)),
  };
}
