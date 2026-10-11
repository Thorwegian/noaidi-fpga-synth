// patch.ts — a sound: one value per parameter, plus whatever a patch file
// held that the companion does not understand
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A Patch is immutable: setValue returns a new one. It stores musical
// intent (values in musical units), never engine state.
//
// Pure TypeScript: no React or native imports.

import {
  dependents, normalize, parameter, parameters,
  type ParameterId, type Value,
} from './parameters';

// A TOML table as smol-toml parses it.
export type TomlTable = { [key: string]: unknown };

export interface Patch {
  readonly values: Readonly<Record<ParameterId, Value>>;
  // File values of known parameters the companion could not interpret,
  // as read: an unknown name or the wrong type, perhaps from newer
  // firmware. The parameter shows its init value; the file value is
  // written back until the parameter is edited.
  readonly unresolved: Readonly<Record<ParameterId, unknown>>;
  // Everything else a file held: unknown keys and tables, unknown keys in
  // known tables and array elements, extra array elements. Written back
  // on save.
  readonly extra: Readonly<TomlTable>;
}

// The init patch: what a file that omits every key loads as. A neutral
// fallback (one saw, open filter, no modulation), not a representative
// sound.
export function initPatch(): Patch {
  const values: Record<ParameterId, Value> = {};
  for (const p of parameters) values[p.id] = p.initValue;
  return { values, unresolved: {}, extra: {} };
}

export function getValue(patch: Patch, id: ParameterId): Value {
  const v = patch.values[id];
  if (v === undefined) throw new RangeError(`unknown parameter ${id}`);
  return v;
}

// patch with parameter id set to value, normalized (clamped, snapped). The
// parameters that depend on id are normalized again: an LFO's depth keeps
// its number but clamps to the new destination's range. Throws RangeError
// for a value the parameter cannot hold.
export function setValue(patch: Patch, id: ParameterId, value: unknown): Patch {
  const p = parameter(id);
  const values: Record<ParameterId, Value> = { ...patch.values };
  const valueOf = (other: ParameterId) => values[other]!;
  const v = normalize(p, value, valueOf);
  if (v === undefined) throw new RangeError(`${id}: cannot hold ${String(value)}`);
  values[id] = v;
  for (const d of dependents(id)) values[d.id] = normalize(d, values[d.id], valueOf)!;

  let unresolved = patch.unresolved;
  if (id in unresolved) {
    const { [id]: _dropped, ...rest } = unresolved;
    unresolved = rest;
  }
  return { values, unresolved, extra: patch.extra };
}

// The IDs whose values differ between a and b.
export function changedIds(a: Patch, b: Patch): ParameterId[] {
  return parameters.filter((p) => a.values[p.id] !== b.values[p.id]).map((p) => p.id);
}
