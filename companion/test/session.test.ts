// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { readPresetFile } from '../src/core/presetFile';
import { factoryEntries, MemoryStorage } from '../src/library/library';
import { ExistsError, PresetSession, SaveError } from '../src/library/session';
import { initPreset } from '../src/core/preset';

const entry = (name: string) => factoryEntries().find((e) => e.name === name)!;

function session() {
  const storage = new MemoryStorage();
  return { storage, session: new PresetSession(storage, initPreset(), 'Init') };
}

describe('PresetSession', () => {
  it('opens a factory preset into the store, clean', async () => {
    const { session: s } = session();
    await s.openEntry(entry('Supersaw'));
    expect(s.store.get('filter.cutoff')).toBe(261.6);
    expect(s.document).toMatchObject({ name: 'Supersaw', dirty: false, readOnly: false });
    s.store.set('filter.cutoff', 1200);
    expect(s.document.dirty).toBe(true);
  });

  it('never writes a factory preset: Save needs Save As', async () => {
    const { session: s, storage } = session();
    await s.openEntry(entry('Supersaw'));
    s.store.set('filter.cutoff', 1200);
    expect(s.canSave()).toBe(false);
    await expect(s.save()).rejects.toThrow(SaveError);
    const saved = await s.saveAs('Pads', 'Supersaw');      // same name: a user preset
    expect(saved).toMatchObject({ source: 'user', path: 'Presets/User/Pads/Supersaw.toml' });
    expect((await storage.list()).every((e) => e.source === 'user')).toBe(true);
    expect(s.canSave()).toBe(true);
  });

  it('Save As, then reopen: the same preset', async () => {
    const { session: s } = session();
    await s.openEntry(entry('Galaxy'));
    s.store.set('filter.resonance', 4.5);
    s.store.set('lfo[1].destination', 'cutoff');
    s.store.set('lfo[1].depth', 36);
    const before = s.store.getPreset().values;
    const saved = await s.saveAs('Pads', 'Galaxy Wide');
    expect(s.document).toMatchObject({ name: 'Galaxy Wide', dirty: false });

    await s.openEntry(entry('Supersaw'));
    await s.openEntry(saved);
    expect(s.store.getPreset().values).toEqual(before);
    expect(s.document.entry).toEqual(saved);
  });

  it('asks before replacing a user preset, and rejects bad names', async () => {
    const { session: s } = session();
    await s.saveAs('Leads', 'Mine');
    await expect(s.saveAs('Leads', 'MINE')).rejects.toThrow(ExistsError);
    await expect(s.saveAs('Leads', 'MINE', true)).resolves.toMatchObject({ name: 'MINE' });
    await expect(s.saveAs('Leads', 'bad/name')).rejects.toThrow(SaveError);
    await expect(s.saveAs('', 'ok')).rejects.toThrow(SaveError);
  });

  it('keeps unknown keys through Save As', async () => {
    const { session: s, storage } = session();
    s.openText('format = 1\nfuture = 7\n[filter]\ncutoff = 900\nshape = "ladder"\n', 'Imported');
    const saved = await s.saveAs('FX', 'Imported');
    const text = await storage.read(saved);
    expect(text).toMatch(/^future = 7$/m);
    expect(text).toMatch(/^shape = "ladder"$/m);
    expect(readPresetFile(text).preset.values['filter.cutoff']).toBe(900);
  });

  it('opens a newer format read-only: no Save, Save As or Export', async () => {
    const { session: s } = session();
    s.openText('format = 2\n[filter]\ncutoff = 900\n', 'Future');
    expect(s.document.readOnly).toBe(true);
    expect(s.document.warnings[0]).toMatch(/newer/);
    expect(s.canSave()).toBe(false);
    expect(s.canSaveAs()).toBe(false);
    expect(() => s.exportText()).toThrow(SaveError);
    await expect(s.saveAs('FX', 'Future')).rejects.toThrow(SaveError);
  });
});
