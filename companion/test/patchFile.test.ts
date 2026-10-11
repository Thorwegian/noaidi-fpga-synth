// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { readFileSync } from 'node:fs';
import { parse } from 'smol-toml';
import { describe, expect, it } from 'vitest';

import { initPatch, setValue } from '../src/core/patch';
import { PatchFileError, readPatchFile, writePatchFile } from '../src/core/patchFile';
import { parameters } from '../src/core/parameters';

const SUPERSAW = new URL('../../app/storage/Patches/Factory/Pads/Supersaw.toml', import.meta.url);

const UNKNOWN = `format = 1
author = "Jens"

[voice]
structure = "4+4"
spread_curve = "wide"

[[osc]]
wave = "noise"
tune = 7

[[osc]]
wave = "pulse"
sync = true

[[osc]]
wave = "saw"

[filter]
cutoff = 1000
drive = { amount = 0.3, mode = "soft" }

[chorus]
rate = 0.5
voices = [1, 2, 3]
`;

describe('readPatchFile', () => {
  it('reads the factory supersaw', () => {
    const { patch, readOnly, warnings } = readPatchFile(readFileSync(SUPERSAW, 'utf8'));
    expect(readOnly).toBe(false);
    expect(warnings).toEqual([]);
    expect(patch.values['voice.structure']).toBe('7+1');
    expect(patch.values['osc[1].wave']).toBe('sine');
    expect(patch.values['osc[1].tune']).toBe(-12);
    expect(patch.values['filter.cutoff']).toBe(370);
    expect(patch.values['lfo[0].destination']).toBe('pitch');
    expect(patch.values['lfo[0].depth']).toBe(0.094);
    expect(patch.values['part.bend_range']).toBe(2);
  });

  it('gives missing keys their init value', () => {
    const { patch } = readPatchFile('format = 1\n[filter]\ncutoff = 500\n');
    expect(patch.values['filter.cutoff']).toBe(500);
    for (const p of parameters)
      if (p.id !== 'filter.cutoff') expect(patch.values[p.id]).toBe(initPatch().values[p.id]);
  });

  it('clamps out-of-range values and keeps special values', () => {
    const { patch } = readPatchFile(
      'format = 1\n[[osc]]\ntune = 100\n[filter]\nresonance = inf\n[part]\nvolume = -inf\n');
    expect(patch.values['osc[0].tune']).toBe(48);
    expect(patch.values['filter.resonance']).toBe(Infinity);
    expect(patch.values['part.volume']).toBe(-Infinity);
  });

  it('opens a newer format read-only, with a warning', () => {
    const r = readPatchFile('format = 2\n[filter]\ncutoff = 500\n');
    expect(r.readOnly).toBe(true);
    expect(r.format).toBe(2);
    expect(r.warnings[0]).toMatch(/format 2 is newer/);
    expect(r.patch.values['filter.cutoff']).toBe(500);
  });

  it('refuses what the synth refuses', () => {
    expect(() => readPatchFile('[filter]\ncutoff = 500\n')).toThrow(PatchFileError);
    expect(() => readPatchFile('format = 1.0\n')).toThrow(/positive integer/);
    expect(() => readPatchFile('format = 0\n')).toThrow(/positive integer/);
    expect(() => readPatchFile('format = 1\n[filter\n')).toThrow(/not valid TOML/);
  });

  it('accepts a byte-order mark and CRLF', () => {
    const { patch } = readPatchFile('﻿format = 1\r\n[filter]\r\ncutoff = 500\r\n');
    expect(patch.values['filter.cutoff']).toBe(500);
  });

  it('drops a known table in the wrong shape, as the synth ignores it', () => {
    const r = readPatchFile('format = 1\nvoice = 3\n');
    expect(r.warnings[0]).toMatch(/voice: not a table/);
    expect(r.patch.extra).toEqual({});
    expect(() => parse(writePatchFile(r.patch))).not.toThrow();
  });
});

describe('unknown content', () => {
  const read = readPatchFile(UNKNOWN);

  it('is reported', () => {
    expect(read.warnings).toContain(
      'osc[0].wave: "noise" not understood; shows its init value "saw", and the file\'s value is kept');
    expect(read.warnings).toContain(
      'kept, not understood: author, voice.spread_curve, osc[1].sync, osc[2].wave, filter.drive, chorus');
    expect(read.patch.values['osc[0].wave']).toBe('saw');
  });

  it('survives an edit and a save', () => {
    const edited = setValue(read.patch, 'filter.cutoff', 2000);
    const saved = parse(writePatchFile(edited)) as any;
    expect(saved.author).toBe('Jens');
    expect(saved.voice).toEqual(expect.objectContaining({ structure: '4+4', spread_curve: 'wide' }));
    expect(saved.osc).toHaveLength(3);
    expect(saved.osc[0].wave).toBe('noise');
    expect(saved.osc[1].sync).toBe(true);
    expect(saved.osc[2]).toEqual({ wave: 'saw' });
    expect(saved.filter.cutoff).toBe(2000);
    expect(saved.filter.drive).toEqual({ amount: 0.3, mode: 'soft' });
    expect(saved.chorus).toEqual({ rate: 0.5, voices: [1, 2, 3] });
  });

  it('keeps its types', () => {
    const saved = parse(writePatchFile(read.patch), { integersAsBigInt: true }) as any;
    expect(saved.chorus.voices).toEqual([1n, 2n, 3n]);
    expect(saved.chorus.rate).toBe(0.5);
  });

  it('is replaced once the parameter is edited', () => {
    const edited = setValue(read.patch, 'osc[0].wave', 'triangle');
    expect(edited.unresolved).toEqual({});
    expect((parse(writePatchFile(edited)) as any).osc[0].wave).toBe('triangle');
  });
});

describe('writePatchFile', () => {
  it('writes every known key, format first', () => {
    const text = writePatchFile(initPatch());
    expect(text.startsWith('format = 1\n')).toBe(true);
    const doc = parse(text) as any;
    for (const p of parameters) {
      const t = p.file.index === undefined ? doc[p.file.table] : doc[p.file.table][p.file.index];
      expect(t).toHaveProperty(p.file.key);
    }
  });

  it('writes special values and integers as TOML has them', () => {
    let patch = setValue(initPatch(), 'filter.resonance', Infinity);
    patch = setValue(patch, 'part.volume', -Infinity);
    const text = writePatchFile(patch);
    expect(text).toMatch(/^resonance = inf$/m);
    expect(text).toMatch(/^volume = -inf$/m);
    expect(text).toMatch(/^bend_range = 2$/m);
  });

  it('is stable: write, read, write gives the same text', () => {
    for (const source of [readFileSync(SUPERSAW, 'utf8'), UNKNOWN]) {
      const once = writePatchFile(readPatchFile(source).patch);
      expect(writePatchFile(readPatchFile(once).patch)).toBe(once);
    }
  });
});
