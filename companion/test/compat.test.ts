// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The companion's patch files against the firmware's own reader and writer
// (tools/patch_tool, built by `make check`, which sets PATCH_TOOL). The
// contract is the musical patch, not the text:
//
//   C writer → TS reader → same patch
//   TS writer → C reader → same patch
//   TS load/save/load and C load/save/load are stable
//
// Without PATCH_TOOL (a plain `npm test`) these tests are skipped.

import { spawnSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import { initPatch, setValue, type Patch } from '../src/core/patch';
import { readPatchFile, writePatchFile } from '../src/core/patchFile';
import {
  effectiveSpec, parameters, type NumberParameter, type Parameter, type Value,
} from '../src/core/parameters';

const TOOL = process.env.PATCH_TOOL;
const STORAGE = fileURLToPath(new URL('../../app/storage/Patches', import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'noaidi-compat-'));
let fileNo = 0;

function file(text: string): string {
  const path = join(dir, `${fileNo++}.toml`);
  writeFileSync(path, text);
  return path;
}

function tool(...args: string[]): { status: number | null; stdout: string; stderr: string } {
  const r = spawnSync(TOOL!, args, { encoding: 'utf8' });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr };
}

// The firmware reads text and saves it back.
function cCanon(text: string): string {
  const r = tool('canon', file(text));
  expect(r.stderr).toBe('');
  expect(r.status).toBe(0);
  return r.stdout;
}

// Keys where the firmware loads a and b differently.
function cDiff(a: string, b: string): string {
  return tool('diff', file(a), file(b)).stdout;
}

function factoryPatches(): string[] {
  return (readdirSync(STORAGE, { recursive: true }) as string[])
    .filter((f) => f.endsWith('.toml')).map((f) => join(STORAGE, f));
}

// A small deterministic generator (mulberry32).
function random(seed: number): () => number {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomValue(p: Parameter, patch: Patch, rnd: () => number): Value {
  if (p.kind === 'name') return p.names[Math.floor(rnd() * p.names.length)]!;
  const spec = effectiveSpec(p, (id) => patch.values[id]!);
  if (spec.special.length > 0 && rnd() < 0.1) return spec.special[0]!;
  const { min, max } = spec.range;
  const x = rnd();
  return p.nearest === 'ratio' && min > 0 ? min * Math.pow(max / min, x) : min + x * (max - min);
}

describe.skipIf(!TOOL)('compatibility with the firmware reader', () => {
  it('finds the factory patches', () => {
    expect(factoryPatches().length).toBeGreaterThan(0);
  });

  it('C writer → TS reader → TS writer → C reader: the same patch', () => {
    for (const path of factoryPatches()) {
      const c = cCanon(readFileSync(path, 'utf8'));
      const ts = writePatchFile(readPatchFile(c).patch);
      expect(cDiff(c, ts), path).toBe('');
      expect(readPatchFile(ts).patch.values).toEqual(readPatchFile(c).patch.values);
    }
  });

  it('TS writer → C reader: random patches load as the TS values', () => {
    const rnd = random(198);
    for (let n = 0; n < 300; n++) {
      let patch = initPatch();
      for (const p of parameters) patch = setValue(patch, p.id, randomValue(p, patch, rnd));
      const ts = writePatchFile(patch);
      const c = cCanon(ts);
      expect(cCanon(c), 'C load/save/load').toBe(c);
      // TS reads the firmware's file back; the firmware must load what TS
      // then writes exactly as it loaded the original: the same raw values
      const back = readPatchFile(c).patch;
      expect(cDiff(ts, writePatchFile(back)), ts).toBe('');
      // names, specials and listed values come back identical
      for (const p of parameters) {
        const mine = patch.values[p.id]!;
        if (p.kind === 'name' || !Number.isFinite(mine)
            || effectiveSpec(p as NumberParameter, (id) => patch.values[id]!).values)
          expect(back.values[p.id], p.id).toBe(mine);
      }
    }
  }, 60_000);   // about 1200 runs of patch_tool

  it('unknown keys do not disturb the firmware', () => {
    const unknown = readPatchFile(`format = 1
author = "Jens"
[voice]
structure = "4+4"
spread_curve = "wide"
[[osc]]
wave = "noise"
tune = 7
[[osc]]
sync = true
[[osc]]
wave = "saw"
[filter]
cutoff = 1000
drive = { amount = 0.3, mode = "soft" }
[chorus]
voices = [1, 2, 3]
`).patch;
    const ts = writePatchFile(setValue(unknown, 'filter.resonance', 4));
    const c = readPatchFile(cCanon(ts)).patch;
    expect(c.values['voice.structure']).toBe('4+4');
    expect(c.values['osc[0].tune']).toBe(7);
    expect(c.values['osc[0].wave']).toBe('saw');   // the firmware's init value for "noise"
    expect(c.values['filter.cutoff']).toBe(1000);
    expect(c.values['filter.resonance']).toBe(4);
  });
});
