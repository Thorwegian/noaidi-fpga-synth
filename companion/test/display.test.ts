// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { initPatch, setValue } from '../src/core/patch';
import { parameters } from '../src/core/parameters';
import { display, displayCoverage } from '../src/display/parameters';

describe('display metadata', () => {
  it('covers every generated parameter, and nothing else', () => {
    expect(displayCoverage()).toEqual({ missing: [], unused: [] });
  });

  it('formats every parameter\'s init value and range ends', () => {
    for (const p of parameters) {
      const d = display(p.id, initPatch());
      expect(d.format(p.initValue)).not.toMatch(/undefined|NaN/);
      if (p.kind === 'number') {
        expect(d.format(p.range.min)).not.toMatch(/undefined|NaN/);
        expect(d.format(p.range.max)).not.toMatch(/undefined|NaN/);
      } else {
        for (const n of p.names) expect(d.choiceLabels?.[n], `${p.id} ${n}`).toBeDefined();
      }
    }
  });

  it('labels array elements from 1', () => {
    expect(display('osc[0].tune').label).toBe('Osc 1 tune');
    expect(display('lfo[1].rate').section).toBe('LFO 2');
  });

  it('gives an LFO depth its destination\'s unit', () => {
    let patch = setValue(initPatch(), 'lfo[0].destination', 'pulse_width');
    expect(display('lfo[0].depth', patch).format(12.5)).toBe('+12.5 pts');
    patch = setValue(patch, 'lfo[0].destination', 'cutoff');
    expect(display('lfo[0].depth', patch).format(-24)).toBe('−24.00 st');
  });

  it('formats special values in words', () => {
    expect(display('filter.resonance').format(Infinity)).toBe('Self-oscillating');
    expect(display('part.volume').format(-Infinity)).toBe('Off');
  });
});
