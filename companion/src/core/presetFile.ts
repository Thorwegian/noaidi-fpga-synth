// presetFile.ts — read and write preset files, TOML format 1
// (docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Reading follows the firmware's loader: keys apply in the manifest's
// order, a missing key takes its init value, a value outside the range
// clamps. Unlike the firmware, the companion keeps what it does not
// understand and writes it back: unknown keys and tables, unknown keys in
// known tables and in [[osc]]/[[lfo]] elements, extra array elements, and
// known keys whose value it cannot interpret. Format 1 lets newer firmware
// add keys without raising the format, so an older companion meets them
// in files it otherwise understands.
//
// A file whose format is newer than the companion's reads, but read-only:
// its keys may mean something else. Comments and layout are not kept; the
// writer writes its own clean form. The compatibility contract is the
// musical preset (same values through the C reader), not the text.
//
// Pure TypeScript: no React or native imports.

import { parse, TomlDate } from 'smol-toml';

import { initPreset, type Preset, type TomlTable } from './preset';
import {
  normalize, parameters, PRESET_FILE_FORMAT,
  type Parameter, type ParameterId, type Value,
} from './parameters';

export class PresetFileError extends Error {}

export interface PresetFileRead {
  readonly preset: Preset;
  readonly format: number;
  // The file's format is newer than this companion's: show it, do not save
  // over it.
  readonly readOnly: boolean;
  readonly warnings: readonly string[];
}

// ── Tables ──────────────────────────────────────────────────────────

function isTable(v: unknown): v is TomlTable {
  return typeof v === 'object' && v !== null && !Array.isArray(v) && !(v instanceof Date);
}

function isArrayOfTables(v: unknown): v is TomlTable[] {
  return Array.isArray(v) && v.length > 0 && v.every(isTable);
}

// A copy of the arrays and tables; leaves (dates, numbers, strings) are
// immutable and shared.
function copyTree<T>(v: T): T {
  if (Array.isArray(v)) return v.map(copyTree) as T;
  if (isTable(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, copyTree(x)])) as T;
  return v;
}

// The known tables, in the order they first appear in the manifest, and
// whether each is an array of tables.
const knownTables: ReadonlyMap<string, boolean> = (() => {
  const m = new Map<string, boolean>();
  for (const p of parameters)
    if (!m.has(p.file.table)) m.set(p.file.table, p.file.index !== undefined);
  return m;
})();

function elementOf(tree: TomlTable, p: Parameter): TomlTable | undefined {
  const t = tree[p.file.table];
  if (p.file.index === undefined) return isTable(t) ? t : undefined;
  return Array.isArray(t) && isTable(t[p.file.index]) ? t[p.file.index] : undefined;
}

// ── Reading ─────────────────────────────────────────────────────────

function describe(v: unknown): string {
  return typeof v === 'string' ? `"${v}"` : String(v);
}

export function readPresetFile(text: string): PresetFileRead {
  let doc: TomlTable;
  try {
    doc = parse(text.replace(/^﻿/, ''),
                { integersAsBigInt: true, unsafeKeyBehaviour: 'throw' }) as TomlTable;
  } catch (e) {
    throw new PresetFileError(`not valid TOML: ${(e as Error).message}`);
  }
  if (typeof doc.format !== 'bigint' || doc.format < 1n)
    throw new PresetFileError(doc.format === undefined ? 'no format key'
                                                      : 'format is not a positive integer');
  const format = Number(doc.format);
  const warnings: string[] = [];
  const readOnly = format > PRESET_FILE_FORMAT;
  if (readOnly)
    warnings.push(`format ${format} is newer than this companion's (${PRESET_FILE_FORMAT}): ` +
                  'opened read-only, and values may not mean what they show');

  const extra = copyTree(doc);
  delete extra.format;

  // A known table in the wrong shape is ignored by the synth too; it
  // cannot be written back next to the real table.
  for (const [table, isArray] of knownTables) {
    const t = extra[table];
    if (t !== undefined && !(isArray ? isArrayOfTables(t) : isTable(t))) {
      warnings.push(`${table}: not ${isArray ? 'an array of tables' : 'a table'}; ignored, ` +
                    'and dropped on save');
      delete extra[table];
    }
  }

  const values: Record<ParameterId, Value> = { ...initPreset().values };
  const unresolved: Record<ParameterId, unknown> = {};
  const valueOf = (id: ParameterId) => values[id]!;
  for (const p of parameters) {             // dependencies first
    const el = elementOf(extra, p);
    if (!el || !(p.file.key in el)) continue;
    const raw = el[p.file.key];
    delete el[p.file.key];
    const v = typeof raw === 'boolean' ? undefined : normalize(p, raw, valueOf);
    if (v === undefined) {
      unresolved[p.id] = raw;
      warnings.push(`${p.id}: ${describe(raw)} not understood; shows its init value ` +
                    `${describe(p.initValue)}, and the file's value is kept`);
    } else {
      values[p.id] = v;
    }
  }

  // Known tables emptied by the loop go; array elements keep their
  // positions up to the last one with something left.
  for (const [table, isArray] of knownTables) {
    const t = extra[table];
    if (isArray && Array.isArray(t)) {
      while (t.length > 0 && Object.keys(t[t.length - 1] as TomlTable).length === 0) t.pop();
      if (t.length === 0) delete extra[table];
    } else if (isTable(t) && Object.keys(t).length === 0) {
      delete extra[table];
    }
  }
  const kept = keptPaths(extra);
  if (kept.length > 0)
    warnings.push(`kept, not understood: ${kept.join(', ')}`);

  return { preset: { values, unresolved, extra }, format, readOnly, warnings };
}

function keptPaths(extra: TomlTable): string[] {
  const paths: string[] = [];
  for (const [k, v] of Object.entries(extra)) {
    if (!knownTables.has(k)) { paths.push(k); continue; }
    if (Array.isArray(v))
      v.forEach((el, i) => Object.keys(el as TomlTable).forEach((key) => paths.push(`${k}[${i}].${key}`)));
    else
      Object.keys(v as TomlTable).forEach((key) => paths.push(`${k}.${key}`));
  }
  return paths;
}

// ── Writing ─────────────────────────────────────────────────────────

function key(k: string): string {
  return /^[A-Za-z0-9_-]+$/.test(k) ? k : quote(k);
}

function quote(s: string): string {
  // JSON's escapes are TOML basic-string escapes; TOML also wants DEL escaped
  return JSON.stringify(s).replace(/\u007f/g, '\\u007F');
}

// Any TOML value, inline: tables become inline tables.
function inline(v: unknown): string {
  if (typeof v === 'bigint') return v.toString();
  if (typeof v === 'number') {
    if (Number.isNaN(v)) return 'nan';
    if (!Number.isFinite(v)) return v > 0 ? 'inf' : '-inf';
    const s = String(v);
    return /[.e]/.test(s) ? s : `${s}.0`;       // stays a float
  }
  if (typeof v === 'string') return quote(v);
  if (typeof v === 'boolean') return String(v);
  if (v instanceof TomlDate || v instanceof Date) return v.toISOString();
  if (Array.isArray(v)) return `[${v.map(inline).join(', ')}]`;
  if (isTable(v)) {
    const entries = Object.entries(v).map(([k, x]) => `${key(k)} = ${inline(x)}`);
    return entries.length ? `{ ${entries.join(', ')} }` : '{}';
  }
  throw new PresetFileError(`cannot write ${String(v)}`);
}

// A known parameter's value: its normalized value, or the file's value it
// could not interpret.
function known(preset: Preset, p: Parameter): string {
  if (p.id in preset.unresolved) return inline(preset.unresolved[p.id]);
  const v = preset.values[p.id]!;
  if (typeof v === 'string') return quote(v);
  if (!Number.isFinite(v)) return v > 0 ? 'inf' : '-inf';
  return p.kind === 'number' && p.integer ? String(Math.round(v)) : String(v);
}

function entries(table: TomlTable | undefined): string[] {
  return Object.entries(table ?? {}).map(([k, v]) => `${key(k)} = ${inline(v)}`);
}

// preset as a format-1 preset file. Do not write a preset read from a file
// with readOnly set.
export function writePresetFile(preset: Preset): string {
  const extra = preset.extra;
  const lines: string[] = [`format = ${PRESET_FILE_FORMAT}`];
  const unknownTables: string[] = [];
  for (const [k, v] of Object.entries(extra)) {
    if (knownTables.has(k)) continue;
    if (isTable(v) || isArrayOfTables(v)) unknownTables.push(k);
    else lines.push(`${key(k)} = ${inline(v)}`);
  }

  for (const [table, isArray] of knownTables) {
    const own = parameters.filter((p) => p.file.table === table);
    if (!isArray) {
      lines.push('', `[${key(table)}]`);
      for (const p of own) lines.push(`${p.file.key} = ${known(preset, p)}`);
      lines.push(...entries(extra[table] as TomlTable | undefined));
      continue;
    }
    const kept = (extra[table] as TomlTable[] | undefined) ?? [];
    const count = Math.max(...own.map((p) => p.file.index! + 1), kept.length);
    for (let i = 0; i < count; i++) {
      lines.push('', `[[${key(table)}]]`);
      for (const p of own) if (p.file.index === i) lines.push(`${p.file.key} = ${known(preset, p)}`);
      lines.push(...entries(kept[i]));
    }
  }

  for (const table of unknownTables) {
    const v = extra[table];
    for (const el of isTable(v) ? [v] : (v as TomlTable[])) {
      lines.push('', isTable(v) ? `[${key(table)}]` : `[[${key(table)}]]`);
      lines.push(...entries(el));
    }
  }
  return lines.join('\n') + '\n';
}
