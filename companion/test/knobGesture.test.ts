// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { classifyKnobGesture, DEFAULT_KNOB_GESTURE, KnobGesture } from '../src/simulator/knobGesture';

const CONFIG = { ...DEFAULT_KNOB_GESTURE, radiusPx: 50 };

describe('classifyKnobGesture', () => {
  it('waits for the dead zone', () => {
    expect(classifyKnobGesture({ x: 40, y: 0 }, { x: 40, y: 3 }, CONFIG)).toBe('pending');
  });

  it('calls a drag that starts near the centre vertical, whatever its direction', () => {
    expect(classifyKnobGesture({ x: 5, y: 5 }, { x: 25, y: 5 }, CONFIG)).toBe('vertical');
  });

  it('calls movement around the knob rotary', () => {
    // at 3 o'clock, moving down; at 12 o'clock, moving right
    expect(classifyKnobGesture({ x: 40, y: 0 }, { x: 40, y: 15 }, CONFIG)).toBe('rotary');
    expect(classifyKnobGesture({ x: 0, y: -40 }, { x: 15, y: -40 }, CONFIG)).toBe('rotary');
  });

  it('calls movement along the radius vertical', () => {
    // at 12 o'clock, moving up or down
    expect(classifyKnobGesture({ x: 0, y: -40 }, { x: 0, y: -60 }, CONFIG)).toBe('vertical');
    expect(classifyKnobGesture({ x: 0, y: 40 }, { x: 2, y: 20 }, CONFIG)).toBe('vertical');
  });
});

describe('KnobGesture', () => {
  it('turns with the finger around the centre, clockwise up, and keeps its mode', () => {
    const g = new KnobGesture({ x: 0, y: -40 }, 0.2, CONFIG);
    expect(g.move({ x: 2, y: -40 })).toBeNull();          // inside the dead zone
    g.move({ x: 10, y: -39 });                            // around the rim: rotary
    const p = g.move({ x: 40, y: 0 })!;                   // a quarter turn clockwise in all
    expect(g.mode).toBe('rotary');
    expect(p).toBeCloseTo(0.2 + 90 / 270, 6);
    g.move({ x: 0, y: 30 });                              // radial now, but the mode holds
    expect(g.mode).toBe('rotary');
    expect(g.position).toBeCloseTo(0.2 + 180 / 270, 6);
  });

  it('ignores the finger near the centre in rotary mode', () => {
    const g = new KnobGesture({ x: 40, y: 0 }, 0.5, CONFIG);
    const p = g.move({ x: 40, y: 20 })!;
    expect(g.mode).toBe('rotary');
    expect(g.move({ x: 2, y: 1 })).toBe(p);
  });

  it('wraps across the 9 o\'clock seam', () => {
    const g = new KnobGesture({ x: -40, y: -5 }, 0.5, CONFIG);
    g.move({ x: -40, y: -20 });                          // classifies rotary, clockwise
    g.move({ x: -40, y: 5 });                            // across the ±180° seam, back anticlockwise
    expect(g.position).toBeGreaterThan(0.4);
    expect(g.position).toBeLessThan(0.6);
  });

  it('moves up for up in vertical mode, travelPx for the full travel, clamped', () => {
    const g = new KnobGesture({ x: 0, y: 0 }, 0.5, CONFIG);
    expect(g.move({ x: 0, y: -CONFIG.travelPx / 4 })).toBeCloseTo(0.75, 6);
    expect(g.mode).toBe('vertical');
    expect(g.move({ x: 0, y: -CONFIG.travelPx })).toBe(1);
  });
});
