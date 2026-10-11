// knobGesture.ts — how a drag on a virtual knob turns it: around its
// centre like a real knob, or up and down like a plugin knob
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The simulator's touch handling, not part of the instrument: a hardware
// knob just turns. The mode is decided once per drag, after the finger
// has moved deadZonePx:
// - a drag that starts near the centre is vertical: the angle is unstable
//   there;
// - otherwise movement across the radius (around the knob) is rotary, and
//   movement along it (towards or away from the centre) is vertical.
// The mode then holds until release. Rotary follows the finger's angle,
// sweepDeg for the full travel, clockwise up. Vertical moves travelPx for
// the full travel, up is up: slower, for fine adjustment.
//
// Points are relative to the knob's centre, in pixels, y down.
//
// Pure TypeScript: no React or native imports.

export interface Point {
  readonly x: number;
  readonly y: number;
}

export interface KnobGestureConfig {
  readonly radiusPx: number;
  readonly deadZonePx: number;       // movement before the mode is decided
  readonly innerFraction: number;    // of the radius: closer is "near the centre"
  readonly travelPx: number;         // vertical drag for the full travel
  readonly sweepDeg: number;         // rotary angle for the full travel
  readonly tangentialBias: number;   // across / along the radius ratio that means rotary
}

export const DEFAULT_KNOB_GESTURE: Omit<KnobGestureConfig, 'radiusPx'> = {
  deadZonePx: 6,
  innerFraction: 0.3,
  travelPx: 240,
  sweepDeg: 270,
  tangentialBias: 1.2,
};

export type KnobMode = 'pending' | 'rotary' | 'vertical';

const length = (p: Point) => Math.hypot(p.x, p.y);

export function classifyKnobGesture(start: Point, now: Point, config: KnobGestureConfig): KnobMode {
  const d = { x: now.x - start.x, y: now.y - start.y };
  if (length(d) < config.deadZonePx) return 'pending';
  const r = length(start);
  if (r < config.innerFraction * config.radiusPx) return 'vertical';
  const radial = { x: start.x / r, y: start.y / r };
  const along = Math.abs(d.x * radial.x + d.y * radial.y);
  const across = Math.abs(-d.x * radial.y + d.y * radial.x);
  return across > config.tangentialBias * along ? 'rotary' : 'vertical';
}

export class KnobGesture {
  private modeNow: KnobMode = 'pending';
  private positionNow: number;
  private lastAngle = 0;
  private startPositionForVertical = 0;

  constructor(private readonly start: Point, startPosition: number,
              private readonly config: KnobGestureConfig) {
    this.positionNow = startPosition;
    this.lastAngle = Math.atan2(start.y, start.x);
  }

  get mode(): KnobMode { return this.modeNow; }
  get position(): number { return this.positionNow; }

  // The knob's position (0 … 1) after the finger moved to now, or null
  // while the mode is still pending.
  move(now: Point): number | null {
    if (this.modeNow === 'pending') {
      this.modeNow = classifyKnobGesture(this.start, now, this.config);
      if (this.modeNow === 'pending') return null;
      this.startPositionForVertical = this.positionNow;   // the dead zone's movement counts
    }
    if (this.modeNow === 'vertical') {
      const p = this.startPositionForVertical - (now.y - this.start.y) / this.config.travelPx;
      this.positionNow = clamp01(p);
      return this.positionNow;
    }
    // rotary: skip points too near the centre, where the angle jumps
    if (length(now) < this.config.innerFraction * this.config.radiusPx * 0.5) return this.positionNow;
    const angle = Math.atan2(now.y, now.x);
    let delta = angle - this.lastAngle;
    if (delta > Math.PI) delta -= 2 * Math.PI;
    if (delta < -Math.PI) delta += 2 * Math.PI;
    this.lastAngle = angle;
    this.positionNow = clamp01(this.positionNow + (delta * 180 / Math.PI) / this.config.sweepDeg);
    return this.positionNow;
  }
}

const clamp01 = (x: number) => Math.min(Math.max(x, 0), 1);
