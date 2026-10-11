// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { initPatch, setValue } from '../src/core/patch';
import {
  assignmentFor, initialSurfaceState, positionToValue, reduceSurface, screenView,
  turnEncoder, validateLayout, valueToPosition, type Assignment, type Layout,
} from '../src/core/surface';

const LAYOUT: Layout = {
  name: 'test',
  grid: { columns: 4, rows: 3 },
  display: { at: [2, 0], span: [2, 2] },
  controls: [
    { id: 'cutoff', kind: 'knob', at: [0, 0] },
    { id: 'attack', kind: 'fader', at: [1, 0] },
    { id: 'e1', kind: 'encoder', at: [0, 1] },
    { id: 'bOsc', kind: 'button', at: [0, 2] },
    { id: 'bLfo', kind: 'button', at: [1, 2] },
  ],
  fixed: {
    cutoff: { param: 'filter.cutoff', range: { min: 20, max: 14388.3 } },
    attack: { param: 'amp_env.attack' },
  },
  layers: [
    { id: 'osc', label: 'OSC', button: 'bOsc', assign: { e1: { param: 'osc[0].wave' } } },
    { id: 'lfo', label: 'LFO', button: 'bLfo', assign: { e1: { param: 'lfo[0].rate' } } },
  ],
  screen: { focusTimeoutMs: 1500 },
  encoderStepsPerTravel: 100,
};

describe('validateLayout', () => {
  it('accepts a sound layout', () => {
    expect(validateLayout(LAYOUT)).toEqual([]);
  });

  it('names what is wrong', () => {
    const bad: Layout = {
      ...LAYOUT,
      fixed: { e1: { param: 'filter.cutoff' }, cutoff: { param: 'no.such' } },
      layers: [{ id: 'x', label: 'X', button: 'cutoff', assign: { attack: { param: 'osc[0].tune' } } }],
    };
    expect(validateLayout(bad)).toEqual([
      'fixed: e1 is a encoder',
      'fixed: no parameter no.such',
      'layer x: cutoff is not a button',
      'layer x: attack is a fader',
      'attack: a fader with no assignment',
    ]);
  });
});

describe('tapers', () => {
  const cases: Assignment[] = [
    { param: 'filter.cutoff', range: { min: 20, max: 14388.3 } },             // exponential by default
    { param: 'osc[0].tune', range: { min: -12, max: 12 } },                    // linear
    { param: 'mod_env.depth', range: { min: -48, max: 48 }, taper: 'bipolarSquare' },
  ];
  it('are inverse', () => {
    for (const a of cases)
      for (const x of [0, 0.1, 0.25, 0.5, 0.8, 1])
        expect(valueToPosition(a, positionToValue(a, x))).toBeCloseTo(x, 9);
  });

  it('map the ends and middle as named', () => {
    expect(positionToValue(cases[0]!, 0.5)).toBeCloseTo(Math.sqrt(20 * 14388.3), 6);
    expect(positionToValue(cases[1]!, 0.5)).toBe(0);
    expect(positionToValue(cases[2]!, 0.75)).toBe(12);   // a quarter of the way out, squared
    expect(valueToPosition(cases[1]!, 48)).toBe(1);    // outside the panel range: at the end
  });
});

describe('turnEncoder', () => {
  it('steps through names and moves numbers along the panel travel', () => {
    const p1 = turnEncoder(LAYOUT, initPatch(), { param: 'osc[0].wave' }, 2);
    expect(p1.values['osc[0].wave']).toBe('triangle');
    const a = { param: 'osc[0].tune', range: { min: -12, max: 12 } };
    const p2 = turnEncoder(LAYOUT, setValue(initPatch(), 'osc[0].tune', 0), a, 10);
    expect(p2.values['osc[0].tune']).toBeCloseTo(2.4, 2);
  });
});

describe('focus and screen', () => {
  it('follows the rules', () => {
    let s = initialSurfaceState(LAYOUT, 0);
    expect(screenView(LAYOUT, s)).toEqual({ mode: 'layer', layer: LAYOUT.layers[0] });

    s = reduceSurface(LAYOUT, s, { type: 'control', control: 'cutoff', time: 100 });
    expect(screenView(LAYOUT, s)).toMatchObject({ mode: 'parameter', focus: { param: 'filter.cutoff' } });

    s = reduceSurface(LAYOUT, s, { type: 'control', control: 'e1', time: 200 });
    expect(s.focus).toEqual({ control: 'e1', param: 'osc[0].wave' });

    s = reduceSurface(LAYOUT, s, { type: 'button', control: 'bLfo', time: 300 });
    expect(screenView(LAYOUT, s)).toEqual({ mode: 'layer', layer: LAYOUT.layers[1] });
    expect(assignmentFor(LAYOUT, s, 'e1')).toEqual({ param: 'lfo[0].rate' });

    s = reduceSurface(LAYOUT, s, { type: 'control', control: 'e1', time: 400 });
    s = reduceSurface(LAYOUT, s, { type: 'tick', time: 1899 });
    expect(s.focus?.param).toBe('lfo[0].rate');
    s = reduceSurface(LAYOUT, s, { type: 'tick', time: 1900 });
    expect(screenView(LAYOUT, s).mode).toBe('layer');
  });
});
