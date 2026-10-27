// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { readFileSync } from 'node:fs';
import { parse } from 'smol-toml';
import { describe, expect, it } from 'vitest';

import { initPreset, setValue } from '../src/core/preset';
import { PresetFileError, readPresetFile, writePresetFile } from '../src/core/presetFile';
import { parameters } from '../src/core/parameters';

const SUPERSAW = new URL('../../app/storage/Presets/Factory/Pads/Supersaw.toml', import.meta.url);

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

describe('readPresetFile', () => {
  it('reads the factory supersaw', () => {
    const { preset, readOnly, warnings } = readPresetFile(readFileSync(SUPERSAW, 'utf8'));
    expect(readOnly).toBe(false);
    expect(warnings).toEqual([]);
    expect(preset.values['voice.structure']).toBe('7+1');
    expect(preset.values['osc[1].wave']).toBe('sine');
    expect(preset.values['osc[1].tune']).toBe(-12);
    expect(preset.values['filter.cutoff']).toBe(261.6);
    expect(preset.values['lfo[0].destination']).toBe('pitch');
    expect(preset.values['lfo[0].depth']).toBe(0.094);
    expect(preset.values['part.bend_range']).toBe(2);
  });

  it('gives missing keys their init value', () => {
    const { preset } = readPresetFile('format = 1\n[filter]\ncutoff = 500\n');
    expect(preset.values['filter.cutoff']).toBe(500);
    for (const p of parameters)
      if (p.id !== 'filter.cutoff') expect(preset.values[p.id]).toBe(initPreset().values[p.id]);
  });

  it('clamps out-of-range values and keeps special values', () => {
    const { preset } = readPresetFile(
      'format = 1\n[[osc]]\ntune = 100\n[filter]\nresonance = inf\n[part]\nvolume = -inf\n');
    expect(preset.values['osc[0].tune']).toBe(48);
    expect(preset.values['filter.resonance']).toBe(Infinity);
    expect(preset.values['part.volume']).toBe(-Infinity);
  });

  it('opens a newer format read-only, with a warning', () => {
    const r = readPresetFile('format = 2\n[filter]\ncutoff = 500\n');
    expect(r.readOnly).toBe(true);
    expect(r.format).toBe(2);
    expect(r.warnings[0]).toMatch(/format 2 is newer/);
    expect(r.preset.values['filter.cutoff']).toBe(500);
  });

  it('refuses what the synth refuses', () => {
    expect(() => readPresetFile('[filter]\ncutoff = 500\n')).toThrow(PresetFileError);
    expect(() => readPresetFile('format = 1.0\n')).toThrow(/positive integer/);
    expect(() => readPresetFile('format = 0\n')).toThrow(/positive integer/);
    expect(() => readPresetFile('format = 1\n[filter\n')).toThrow(/not valid TOML/);
  });

  it('accepts a byte-order mark and CRLF', () => {
    const { preset } = readPresetFile('﻿format = 1\r\n[filter]\r\ncutoff = 500\r\n');
    expect(preset.values['filter.cutoff']).toBe(500);
  });

  it('drops a known table in the wrong shape, as the synth ignores it', () => {
    const r = readPresetFile('format = 1\nvoice = 3\n');
    expect(r.warnings[0]).toMatch(/voice: not a table/);
    expect(r.preset.extra).toEqual({});
    expect(() => parse(writePresetFile(r.preset))).not.toThrow();
  });
});

describe('unknown content', () => {
  const read = readPresetFile(UNKNOWN);

  it('is reported', () => {
    expect(read.warnings).toContain(
      'osc[0].wave: "noise" not understood; shows its init value "saw", and the file\'s value is kept');
    expect(read.warnings).toContain(
      'kept, not understood: author, voice.spread_curve, osc[1].sync, osc[2].wave, filter.drive, chorus');
    expect(read.preset.values['osc[0].wave']).toBe('saw');
  });

  it('survives an edit and a save', () => {
    const edited = setValue(read.preset, 'filter.cutoff', 2000);
    const saved = parse(writePresetFile(edited)) as any;
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
    const saved = parse(writePresetFile(read.preset), { integersAsBigInt: true }) as any;
    expect(saved.chorus.voices).toEqual([1n, 2n, 3n]);
    expect(saved.chorus.rate).toBe(0.5);
  });

  it('is replaced once the parameter is edited', () => {
    const edited = setValue(read.preset, 'osc[0].wave', 'triangle');
    expect(edited.unresolved).toEqual({});
    expect((parse(writePresetFile(edited)) as any).osc[0].wave).toBe('triangle');
  });
});

describe('writePresetFile', () => {
  it('writes every known key, format first', () => {
    const text = writePresetFile(initPreset());
    expect(text.startsWith('format = 1\n')).toBe(true);
    const doc = parse(text) as any;
    for (const p of parameters) {
      const t = p.file.index === undefined ? doc[p.file.table] : doc[p.file.table][p.file.index];
      expect(t).toHaveProperty(p.file.key);
    }
  });

  it('writes special values and integers as TOML has them', () => {
    let preset = setValue(initPreset(), 'filter.resonance', Infinity);
    preset = setValue(preset, 'part.volume', -Infinity);
    const text = writePresetFile(preset);
    expect(text).toMatch(/^resonance = inf$/m);
    expect(text).toMatch(/^volume = -inf$/m);
    expect(text).toMatch(/^bend_range = 2$/m);
  });

  it('is stable: write, read, write gives the same text', () => {
    for (const source of [readFileSync(SUPERSAW, 'utf8'), UNKNOWN]) {
      const once = writePresetFile(readPresetFile(source).preset);
      expect(writePresetFile(readPresetFile(once).preset)).toBe(once);
    }
  });
});
