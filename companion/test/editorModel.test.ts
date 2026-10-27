// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { hasParameter, parameter, parameters } from '../src/core/parameters';
import { readPresetFile } from '../src/core/presetFile';
import { setValue } from '../src/core/preset';
import { positionToValue } from '../src/core/surface';
import { editorControl, editorSections } from '../src/editor/editorModel';
import { factoryEntries, factoryText } from '../src/library/library';

const supersaw = readPresetFile(factoryText(factoryEntries().find((e) => e.name === 'Supersaw')!)).preset;

describe('Editor model', () => {
  it('shows every stored parameter exactly once, in the synth\'s sections', () => {
    const sections = editorSections();
    const shown = sections.flatMap((s) => s.params);
    expect([...shown].sort()).toEqual(parameters.map((p) => p.id).sort());
    expect(new Set(shown).size).toBe(shown.length);
    expect(sections.map((s) => s.title)).toEqual(
      ['Voice', 'Osc 1', 'Osc 2', 'Filter', 'Amp envelope', 'Mod envelope', 'LFO 1', 'LFO 2', 'Part']);
  });

  it('gives every parameter a control that fits it', () => {
    for (const p of parameters) {
      const c = editorControl(p.id, supersaw);
      expect(hasParameter(p.id)).toBe(true);
      if (p.kind === 'name') {
        expect(c.kind, p.id).toBe('choice');
        if (c.kind === 'choice') expect(c.options.map((o) => o.value)).toEqual(p.names);
      }
      if (c.kind === 'slider') expect(c.assignment.param).toBe(p.id);
    }
  });

  it('spans the whole engine range, not a panel range', () => {
    const c = editorControl('amp_env.release', supersaw);
    expect(c.kind).toBe('slider');
    if (c.kind !== 'slider') return;
    const p = parameter('amp_env.release');
    expect(c.assignment.range).toEqual(p.kind === 'number' ? p.range : undefined);
    expect(c.assignment.taper).toBe('exponential');
    expect(positionToValue(c.assignment, 1)).toBeCloseTo(150.902, 3);
  });

  it('centres bipolar parameters and offers special values', () => {
    const depth = editorControl('mod_env.depth', supersaw);
    expect(depth.kind === 'slider' && depth.bipolar).toBe(true);
    const res = editorControl('filter.resonance', supersaw);
    expect(res.kind === 'slider' && res.special).toEqual([Infinity]);
  });

  it('follows an LFO\'s destination for its depth range', () => {
    const range = (dest: string) => {
      const c = editorControl('lfo[0].depth', setValue(supersaw, 'lfo[0].destination', dest));
      return c.kind === 'slider' ? c.assignment.range : undefined;
    };
    expect(range('pitch')).toEqual({ min: -48, max: 48 });
    expect(range('cutoff')).toEqual({ min: -129, max: 129 });
    expect(range('pulse_width')).toEqual({ min: -50, max: 50 });
  });

  it('makes the 12/24 dB slope a choice and bend range a stepper', () => {
    const slope = editorControl('filter.slope', supersaw);
    expect(slope.kind === 'choice' && slope.options.map((o) => o.value)).toEqual([12, 24]);
    expect(editorControl('part.bend_range', supersaw).kind).toBe('stepper');
  });
});
