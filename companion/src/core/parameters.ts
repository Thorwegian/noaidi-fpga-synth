// parameters.ts — the synth's parameters, as the generated manifest
// describes them
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// src/generated/parameters.json comes from the firmware's preset-file table
// (tools/gen_manifest), so this module adds no knowledge of the engine: it
// types the manifest and applies its rules. A value is a number in the
// parameter's musical unit (±Infinity for the special values "inf" and
// "-inf") or, for a name parameter, one of its names.
//
// Pure TypeScript: no React or native imports.

import manifest from '../generated/parameters.json';

export type ParameterId = string;
export type Value = number | string;

export interface FileLocation {
  readonly table: string;
  readonly index?: number;   // element of an array of tables ([[osc]], [[lfo]])
  readonly key: string;
}

export interface Range {
  readonly min: number;
  readonly max: number;
}

// What a number parameter can hold, possibly for one value of the
// parameter it depends on.
export interface ValueSpec {
  readonly range: Range;
  readonly special: readonly number[];   // ±Infinity
  readonly valueCount?: number;
  readonly values?: readonly number[];   // ascending; listed when there are few
}

interface ParameterBase {
  readonly id: ParameterId;
  readonly file: FileLocation;
}

export interface NameParameter extends ParameterBase {
  readonly kind: 'name';
  readonly names: readonly string[];
  readonly initValue: string;
}

export interface NumberParameter extends ParameterBase, ValueSpec {
  readonly kind: 'number';
  readonly integer: boolean;
  readonly nearest: 'difference' | 'ratio';
  readonly initValue: number;
  readonly dependsOn?: ParameterId;
  readonly byValue?: Readonly<Record<string, ValueSpec>>;
}

export type Parameter = NameParameter | NumberParameter;

// ── The manifest ────────────────────────────────────────────────────

type RawSpec = { range: Range; special?: string[]; valueCount?: number; values?: number[] };

function specialValue(text: string): number {
  if (text === 'inf') return Infinity;
  if (text === '-inf') return -Infinity;
  throw new Error(`parameters.json: unknown special value ${text}`);
}

function valueSpec(raw: RawSpec): ValueSpec {
  return {
    range: raw.range,
    special: (raw.special ?? []).map(specialValue),
    valueCount: raw.valueCount,
    values: raw.values,
  };
}

function toParameter(raw: any): Parameter {
  const base = { id: raw.id, file: raw.file };
  if (raw.kind === 'name')
    return { ...base, kind: 'name', names: raw.names, initValue: raw.initValue };
  const byValue = raw.byValue
    ? Object.fromEntries(Object.entries(raw.byValue).map(([k, v]) => [k, valueSpec(v as RawSpec)]))
    : undefined;
  return {
    ...base,
    ...valueSpec(raw),
    kind: 'number',
    integer: raw.integer,
    nearest: raw.nearest,
    initValue: typeof raw.initValue === 'string' ? specialValue(raw.initValue) : raw.initValue,
    dependsOn: raw.dependsOn,
    byValue,
  };
}

// The preset file format the manifest was generated for.
export const PRESET_FILE_FORMAT: number = manifest.presetFileFormat;

// Every parameter, in the order the firmware's loader applies them: a
// parameter comes after the one it depends on.
export const parameters: readonly Parameter[] = manifest.parameters.map(toParameter);

const byId = new Map(parameters.map((p) => [p.id, p]));

export function hasParameter(id: ParameterId): boolean {
  return byId.has(id);
}

export function parameter(id: ParameterId): Parameter {
  const p = byId.get(id);
  if (!p) throw new RangeError(`unknown parameter ${id}`);
  return p;
}

// The parameters whose conversion depends on id.
export function dependents(id: ParameterId): readonly NumberParameter[] {
  return parameters.filter((p): p is NumberParameter => p.kind === 'number' && p.dependsOn === id);
}

// ── Values ──────────────────────────────────────────────────────────

// What p can hold, given the values of the other parameters. A dependency
// on a name picks that name's spec; a dependency on a number (none today)
// keeps the union range, which the engine narrows.
export function effectiveSpec(p: NumberParameter, valueOf: (id: ParameterId) => Value): ValueSpec {
  if (p.dependsOn && p.byValue) {
    const spec = p.byValue[String(valueOf(p.dependsOn))];
    if (spec) return spec;
  }
  return p;
}

// Significant digits kept of a value that is not snapped to a listed
// value: enough for every raw value (pulse width needs 8), and stable
// through a write and a read.
const SIGNIFICANT_DIGITS = 9;

// Of neighbours a < b, the one nearer v; an exact tie goes to the one
// further from zero, as in the firmware.
function closer(p: NumberParameter, v: number, a: number, b: number): number {
  const [da, db] = p.nearest === 'ratio' && v > 0 && a > 0
    ? [Math.abs(Math.log(v / a)), Math.abs(Math.log(b / v))]
    : [v - a, b - v];
  if (da !== db) return da < db ? a : b;
  return Math.abs(a) > Math.abs(b) ? a : b;
}

// The listed value nearest to v, by the parameter's own measure.
function snap(p: NumberParameter, values: readonly number[], v: number): number {
  let lo = 0, hi = values.length - 1;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (values[mid]! <= v) lo = mid; else hi = mid;
  }
  return closer(p, v, values[lo]!, values[hi]!);
}

// value as p holds it: clamped to the range the engine has, an integer
// for an integer parameter, snapped to the nearest listed value, or kept
// to SIGNIFICANT_DIGITS. undefined if value is not something p can hold
// (a name it does not have, a string for a number, NaN).
export function normalize(p: Parameter, value: unknown, valueOf: (id: ParameterId) => Value): Value | undefined {
  if (p.kind === 'name')
    return typeof value === 'string' && p.names.includes(value) ? value : undefined;

  const given = typeof value === 'bigint' ? Number(value) : value;
  if (typeof given !== 'number' || Number.isNaN(given)) return undefined;
  const spec = effectiveSpec(p, valueOf);
  if (spec.special.includes(given)) return given;
  let v = Math.min(Math.max(given, spec.range.min), spec.range.max);
  if (p.integer) v = Math.round(v);
  if (spec.values && spec.values.length > 0) return snap(p, spec.values, v);
  return v === 0 ? 0 : Number(v.toPrecision(SIGNIFICANT_DIGITS));
}
