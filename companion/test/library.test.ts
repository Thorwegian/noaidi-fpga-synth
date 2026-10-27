// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { readPresetFile } from '../src/core/presetFile';
import { FACTORY_FILES, PRESET_CATEGORIES } from '../src/generated/factoryPresets';
import { entryOf, factoryEntries, factoryText, MemoryStorage, startupEntry } from '../src/library/library';
import { presetNameProblem, validPresetName } from '../src/library/presetName';

describe('factory library', () => {
  it('lists every factory preset in the firmware tree, by category', () => {
    const entries = factoryEntries();
    const files = Object.keys(FACTORY_FILES).filter((p) => p.startsWith('Presets/Factory/'));
    expect(entries.map((e) => e.path).sort()).toEqual(files.sort());
    expect(entries.length).toBeGreaterThanOrEqual(5);
    for (const e of entries) {
      expect(e.source).toBe('factory');
      expect(PRESET_CATEGORIES).toContain(e.category);
    }
    expect(entries.map((e) => `${e.category}/${e.name}`)).toContain('Pads/Supersaw');
  });

  it('opens every factory preset cleanly', () => {
    for (const e of factoryEntries()) {
      const read = readPresetFile(factoryText(e));
      expect(read.readOnly, e.path).toBe(false);
      expect(read.warnings, e.path).toEqual([]);
    }
  });

  it('starts with the preset system.toml names', () => {
    expect(startupEntry()?.path).toBe('Presets/Factory/Pads/Supersaw.toml');
  });

  it('has the firmware\'s categories', () => {
    expect(PRESET_CATEGORIES).toEqual(expect.arrayContaining(['Basses', 'Leads', 'Pads', 'Strings']));
  });

  it('reads only the layout\'s preset paths', () => {
    expect(entryOf('Presets/User/Leads/My Lead.toml')).toEqual(
      { source: 'user', category: 'Leads', name: 'My Lead', path: 'Presets/User/Leads/My Lead.toml' });
    expect(entryOf('system.toml')).toBeUndefined();
    expect(entryOf('Presets/User/Loose.toml')).toBeUndefined();
  });
});

describe('MemoryStorage', () => {
  it('writes under Presets/User and replaces a name that differs only in case', async () => {
    const s = new MemoryStorage();
    await s.write('Pads', 'Warm', 'a');
    await s.write('Pads', 'WARM', 'b');
    const list = await s.list();
    expect(list.map((e) => e.path)).toEqual(['Presets/User/Pads/WARM.toml']);
    expect(await s.exists('Pads', 'warm')).toBe(true);
    expect(await s.read(list[0]!)).toBe('b');
  });
});

describe('preset names', () => {
  it('follow docs/storage_format.md', () => {
    expect(validPresetName('Ærlig Gjøk')).toBe(true);
    expect(validPresetName('a'.repeat(64))).toBe(true);
    expect(presetNameProblem('')).not.toBeNull();
    expect(presetNameProblem('a'.repeat(65))).not.toBeNull();
    expect(presetNameProblem('a/b')).not.toBeNull();
    expect(presetNameProblem(' lead')).not.toBeNull();
    expect(presetNameProblem('lead.')).not.toBeNull();
  });
});
