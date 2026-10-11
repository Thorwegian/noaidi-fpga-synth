// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import {
  dependents, normalize, parameter, parameters, PATCH_FILE_FORMAT,
  type NumberParameter, type ParameterId, type Value,
} from '../src/core/parameters';

const init = (id: ParameterId): Value => parameter(id).initValue;
const num = (id: ParameterId) => parameter(id) as NumberParameter;

describe('manifest', () => {
  it('describes format 1 and the arrays of tables', () => {
    expect(PATCH_FILE_FORMAT).toBe(1);
    expect(parameters.map((p) => p.id)).toContain('osc[1].tune');
    expect(parameters.map((p) => p.id)).toContain('lfo[1].depth');
    expect(parameter('osc[1].tune').file).toEqual({ table: 'osc', index: 1, key: 'tune' });
  });

  it('turns special values into infinities', () => {
    expect(num('filter.resonance').special).toEqual([Infinity]);
    expect(num('part.volume').special).toEqual([-Infinity]);
  });

  it('lists each dependency after the parameter it depends on', () => {
    const order = parameters.map((p) => p.id);
    for (const p of parameters)
      if (p.kind === 'number' && p.dependsOn)
        expect(order.indexOf(p.dependsOn)).toBeLessThan(order.indexOf(p.id));
    expect(dependents('lfo[0].destination').map((p) => p.id)).toEqual(['lfo[0].depth']);
    expect(dependents('amp_env.sustain').map((p) => p.id)).toEqual(['amp_env.decay']);
  });
});

describe('normalize', () => {
  it('accepts only known names', () => {
    expect(normalize(parameter('osc[0].wave'), 'sine', init)).toBe('sine');
    expect(normalize(parameter('osc[0].wave'), 'noise', init)).toBeUndefined();
    expect(normalize(parameter('osc[0].wave'), 3, init)).toBeUndefined();
  });

  it('clamps to the engine range', () => {
    expect(normalize(parameter('osc[0].tune'), 100, init)).toBe(48);
    expect(normalize(parameter('osc[0].tune'), -100, init)).toBe(-48);
    expect(normalize(parameter('filter.cutoff'), 1e9, init)).toBe(14388.3);
    expect(normalize(parameter('filter.resonance'), 1000, init)).toBe(32);
  });

  it('keeps special values and clamps other infinities', () => {
    expect(normalize(parameter('filter.resonance'), Infinity, init)).toBe(Infinity);
    expect(normalize(parameter('part.volume'), -Infinity, init)).toBe(-Infinity);
    expect(normalize(parameter('osc[0].tune'), Infinity, init)).toBe(48);
  });

  it('rejects NaN and non-numbers for numbers, and takes bigints', () => {
    expect(normalize(parameter('osc[0].tune'), NaN, init)).toBeUndefined();
    expect(normalize(parameter('osc[0].tune'), '3', init)).toBeUndefined();
    expect(normalize(parameter('part.bend_range'), 12n, init)).toBe(12);
  });

  it('rounds integer parameters', () => {
    expect(normalize(parameter('part.bend_range'), 2.6, init)).toBe(3);
  });

  it('snaps to listed values by difference', () => {
    // slope: 12 or 24, the firmware switches at 18
    expect(normalize(parameter('filter.slope'), 17.4, init)).toBe(12);
    expect(normalize(parameter('filter.slope'), 18, init)).toBe(24);
    const step = 100 / 127;   // unison_stereo
    expect(normalize(parameter('voice.unison_stereo'), step * 10.4, init))
      .toBe(num('voice.unison_stereo').values![10]);
  });

  it('snaps to listed values by ratio', () => {
    const values = num('amp_env.attack').values!;
    const [a, b] = [values[100]!, values[101]!];
    const geometric = Math.sqrt(a * b), arithmetic = (a + b) / 2;
    const between = (geometric + arithmetic) / 2;   // nearer a by difference, b by ratio
    expect(normalize(parameter('amp_env.attack'), between, init)).toBe(b);
    expect(normalize(parameter('amp_env.attack'), 0, init)).toBe(values[0]);
  });

  it('keeps unlisted values to 9 significant digits', () => {
    expect(normalize(parameter('filter.cutoff'), 370.123456789123, init)).toBe(370.123457);
  });

  it('clamps a dependent to the range for its dependency', () => {
    const dest = (d: string) => (id: ParameterId) => (id === 'lfo[0].destination' ? d : init(id));
    expect(normalize(parameter('lfo[0].depth'), 100, dest('pitch'))).toBe(48);
    expect(normalize(parameter('lfo[0].depth'), 100, dest('cutoff'))).toBe(100);
    expect(normalize(parameter('lfo[0].depth'), 100, dest('pulse_width'))).toBe(50);
    expect(normalize(parameter('lfo[0].depth'), 100, dest('resonance'))).toBe(5.5);
  });
});
