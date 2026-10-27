// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { readPresetFile } from '../src/core/presetFile';
import { createPresetStore } from '../src/core/presetStore';
import { hasParameter, parameter, type NumberParameter } from '../src/core/parameters';
import { assignmentFor, panelRange, validateLayout } from '../src/core/surface';
import { FACTORY_FILES } from '../src/generated/factoryPresets';
import { layoutA } from '../src/layouts/layoutA';
import { createPanel } from '../src/simulator/panel';

function setup() {
  let now = 0;
  const store = createPresetStore(readPresetFile(FACTORY_FILES['Presets/Factory/Pads/Supersaw.toml']!).preset);
  const panel = createPanel(layoutA, store, () => now);
  return { store, panel, advance: (ms: number) => { now += ms; } };
}

describe('Layout A', () => {
  it('is a valid layout: parameters exist, ranges inside the engine\'s, nothing overlaps', () => {
    expect(validateLayout(layoutA)).toEqual([]);
  });

  it('has the hypothesis\'s ten permanent controls, four encoders and four layer buttons', () => {
    const kinds = (k: string) => layoutA.controls.filter((c) => c.kind === k).map((c) => c.id);
    expect(Object.values(layoutA.fixed).map((a) => a.param).sort()).toEqual([
      'amp_env.attack', 'amp_env.decay', 'amp_env.release', 'amp_env.sustain',
      'filter.cutoff', 'filter.resonance', 'mod_env.depth', 'part.volume',
      'voice.osc_mix', 'voice.unison_detune',
    ]);
    expect(kinds('fader').map((id) => layoutA.fixed[id]!.param)).toEqual(
      ['amp_env.attack', 'amp_env.decay', 'amp_env.sustain', 'amp_env.release']);
    expect(kinds('encoder')).toHaveLength(4);
    expect(kinds('button').map((id) => layoutA.controls.find((c) => c.id === id)!.label))
      .toEqual(['OSC', 'FILTER', 'MOD ENV', 'LFO']);
  });

  it('assigns only existing parameters, at most one per encoder', () => {
    for (const layer of layoutA.layers) {
      for (const [encoder, a] of Object.entries(layer.assign)) {
        expect(['e1', 'e2', 'e3', 'e4']).toContain(encoder);
        expect(hasParameter(a.param), a.param).toBe(true);
      }
      for (const t of layer.overview?.tiles ?? []) expect(hasParameter(t), t).toBe(true);
    }
  });

  it('keeps panel ranges inside the engine ranges, for every destination too', () => {
    const all = [...Object.values(layoutA.fixed), ...layoutA.layers.flatMap((l) => Object.values(l.assign))];
    for (const a of all) {
      const p = parameter(a.param);
      if (p.kind !== 'number') continue;
      const r = panelRange(a);
      expect(r.min, a.param).toBeGreaterThanOrEqual(p.range.min);
      expect(r.max, a.param).toBeLessThanOrEqual(p.range.max);
      for (const [value, range] of Object.entries(a.rangeBy ?? {})) {
        const engine = (p as NumberParameter).byValue![value]!.range;
        expect(range.min).toBeGreaterThanOrEqual(engine.min);
        expect(range.max).toBeLessThanOrEqual(engine.max);
      }
    }
  });
});

describe('Layout A behaviour', () => {
  it('starts on FILTER and switches the encoders with the layer buttons', () => {
    const { panel } = setup();
    const enc = (id: string) => assignmentFor(layoutA, panel.surface.getState(), id)?.param;
    expect(enc('e1')).toBe('filter.type');
    expect(enc('e4')).toBeUndefined();            // deliberately spare
    panel.press('bOsc');
    expect(enc('e1')).toBe('osc[0].wave');
    expect(enc('e3')).toBe('osc[1].tune');
    panel.press('bModEnv');
    expect(enc('e1')).toBe('mod_env.attack');
  });

  it('steps between the two LFOs with the one LFO button', () => {
    const { panel } = setup();
    panel.press('bLfo');
    expect(panel.surface.getState().layerId).toBe('lfo1');
    expect(assignmentFor(layoutA, panel.surface.getState(), 'e1')?.param).toBe('lfo[0].rate');
    panel.press('bLfo');
    expect(panel.surface.getState().layerId).toBe('lfo2');
    expect(assignmentFor(layoutA, panel.surface.getState(), 'e1')?.param).toBe('lfo[1].rate');
    panel.press('bLfo');
    expect(panel.surface.getState().layerId).toBe('lfo1');
  });

  it('focuses a permanent control\'s parameter when it moves, and sets it', () => {
    const { panel, store } = setup();
    panel.move('attack', 1);
    expect(panel.surface.getState().focus).toEqual({ control: 'attack', param: 'amp_env.attack' });
    expect(store.get('amp_env.attack')).toBeCloseTo(10, 0);
    panel.move('cutoff', 0);
    expect(panel.surface.getState().focus?.param).toBe('filter.cutoff');
    expect(store.get('filter.cutoff')).toBeCloseTo(20, 0);
  });

  it('focuses an encoder\'s current parameter when it turns', () => {
    const { panel, store } = setup();
    panel.turn('e1', 1);
    expect(panel.surface.getState().focus).toEqual({ control: 'e1', param: 'filter.type' });
    expect(store.get('filter.type')).toBe('bandpass');
    panel.press('bOsc');
    panel.turn('e3', 1);                             // a semitone per detent
    expect(panel.surface.getState().focus?.param).toBe('osc[1].tune');
    expect(store.get('osc[1].tune')).toBeCloseTo(-11, 6);
  });

  it('gives LFO depth the panel range of its destination', () => {
    const { panel, store } = setup();
    panel.press('bLfo');                             // LFO 1: pitch
    for (let i = 0; i < 100; i++) panel.turn('e2', 1);
    expect(store.get('lfo[0].depth')).toBeCloseTo(12, 6);
    panel.turn('e3', 1);                             // destination: pitch → cutoff
    for (let i = 0; i < 100; i++) panel.turn('e2', 1);
    expect(store.get('lfo[0].depth')).toBeCloseTo(48, 6);
  });

  it('returns to the overview after the timeout', () => {
    const { panel, advance } = setup();
    panel.touch('volume');
    expect(panel.surface.getState().focus?.param).toBe('part.volume');
    advance(layoutA.screen.focusTimeoutMs);
    panel.tick();
    expect(panel.surface.getState().focus).toBeNull();
  });
});
