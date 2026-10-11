// layoutA.ts — Layout A: the first whole-panel hypothesis
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// An experiment, not the Noaidi front panel: ten permanent controls, four
// endless encoders with layers, the real display in the middle. Every
// placement, assignment, range and taper is data here, so Layout B is a
// new file, not new code.
//
// Panel ranges are UX choices inside the engine's ranges (checked by
// test/layoutA.test.ts), chosen for useful resolution under a hand rather
// than reach; the full Editor will expose the engine's whole range.
//
//   col  0      1       2    3    4    5      6   7   8   9
//   row0 Cutoff Reson.  ┌──── display ────┐   A   D   S   R   (faders,
//   row1 EnvDep  ·      └─────────────────┘   │   │   │   │    rows 0-2)
//   row2 OscMix Detune  E1   E2   E3   E4     │   │   │   │
//   row3  ·      ·      OSC  FILT MOD  LFO    ·   ·   ·   Volume

import type { Layout } from '../core/surface';

const PITCH_RANGE = { min: -24, max: 24 };

export const layoutA: Layout = {
  name: 'Layout A',
  hypothesis: 'Ten permanent controls and four layered encoders cover ordinary sound design without menus',
  grid: { columns: 10, rows: 4 },
  display: { at: [2, 0], span: [4, 2] },
  groups: [
    { label: 'FILTER', at: [0, 0], span: [2, 2] },
    { label: 'OSC', at: [0, 2], span: [2, 1] },
    { label: 'AMP ENVELOPE', at: [6, 0], span: [4, 3] },
    { label: 'OUT', at: [9, 3], span: [1, 1] },
  ],
  controls: [
    { id: 'cutoff', kind: 'knob', at: [0, 0] },
    { id: 'resonance', kind: 'knob', at: [1, 0] },
    { id: 'envDepth', kind: 'knob', at: [0, 1], label: 'Env depth' },
    { id: 'oscMix', kind: 'knob', at: [0, 2], label: 'Osc mix' },
    { id: 'detune', kind: 'knob', at: [1, 2], label: 'Detune' },
    { id: 'attack', kind: 'fader', at: [6, 0], span: [1, 3] },
    { id: 'decay', kind: 'fader', at: [7, 0], span: [1, 3] },
    { id: 'sustain', kind: 'fader', at: [8, 0], span: [1, 3] },
    { id: 'release', kind: 'fader', at: [9, 0], span: [1, 3] },
    { id: 'volume', kind: 'knob', at: [9, 3] },
    { id: 'e1', kind: 'encoder', at: [2, 2] },
    { id: 'e2', kind: 'encoder', at: [3, 2] },
    { id: 'e3', kind: 'encoder', at: [4, 2] },
    { id: 'e4', kind: 'encoder', at: [5, 2] },
    { id: 'bOsc', kind: 'button', at: [2, 3], label: 'OSC' },
    { id: 'bFilter', kind: 'button', at: [3, 3], label: 'FILTER' },
    { id: 'bModEnv', kind: 'button', at: [4, 3], label: 'MOD ENV' },
    { id: 'bLfo', kind: 'button', at: [5, 3], label: 'LFO' },
  ],
  fixed: {
    // the audible range, equal ratio per step
    cutoff: { param: 'filter.cutoff', range: { min: 20, max: 14388.3 }, taper: 'exponential' },
    // Butterworth to Q 32, MIDI CC 71's reach; self-oscillation is left to the Editor
    resonance: { param: 'filter.resonance', range: { min: 0.707107, max: 32 }, taper: 'exponential' },
    // ±4 octaves of cutoff, fine near zero (the engine has ±129 semitones)
    envDepth: { param: 'mod_env.depth', range: { min: -48, max: 48 }, taper: 'bipolarSquare' },
    oscMix: { param: 'voice.osc_mix', range: { min: -100, max: 100 }, taper: 'linear' },
    // up to half a semitone per spread step, fine at the bottom where supersaws live
    detune: { param: 'voice.unison_detune', range: { min: 0, max: 0.5 }, taper: 'square' },
    attack: { param: 'amp_env.attack', range: { min: 0.0011, max: 10 }, taper: 'exponential' },
    decay: { param: 'amp_env.decay', range: { min: 0.005, max: 10 }, taper: 'exponential' },
    sustain: { param: 'amp_env.sustain', range: { min: -60.2, max: -0.0587949 }, taper: 'linear' },
    release: { param: 'amp_env.release', range: { min: 0.005, max: 15 }, taper: 'exponential' },
    volume: { param: 'part.volume', range: { min: -60, max: 6 }, taper: 'linear' },
  },
  layers: [
    {
      id: 'filter', label: 'FILTER', button: 'bFilter',
      assign: {
        e1: { param: 'filter.type' },
        e2: { param: 'filter.slope' },
        e3: { param: 'filter.key_track', range: { min: 0, max: 200 }, detents: 40 },
        // e4: deliberately spare
      },
      overview: { tiles: ['filter.cutoff', 'filter.resonance'], graphic: 'filter' },
    },
    {
      id: 'osc', label: 'OSC', button: 'bOsc',
      assign: {
        e1: { param: 'osc[0].wave' },
        e2: { param: 'osc[1].wave' },
        e3: { param: 'osc[1].tune', range: PITCH_RANGE, detents: 48 },   // a semitone per detent
        e4: { param: 'voice.structure' },
      },
      overview: {
        tiles: ['osc[0].tune', 'osc[0].pulse_width', 'voice.osc_mix', 'voice.unison_detune'],
        graphic: 'none',
      },
    },
    {
      id: 'modEnv', label: 'MOD ENV', button: 'bModEnv',
      assign: {
        e1: { param: 'mod_env.attack', range: { min: 0.0011, max: 10 }, detents: 48 },
        e2: { param: 'mod_env.decay', range: { min: 0.005, max: 10 }, detents: 48 },
        e3: { param: 'mod_env.sustain', range: { min: 0, max: 99.9023 }, detents: 50 },
        e4: { param: 'mod_env.release', range: { min: 0.005, max: 15 }, detents: 48 },
      },
      overview: { tiles: ['mod_env.depth', 'mod_env.velocity'], graphic: 'modEnv' },
    },
    lfoLayer(0),
    lfoLayer(1),
  ],
  screen: { focusTimeoutMs: 2000 },
  encoderStepsPerTravel: 64,
};

// The two LFOs share the LFO button: each press shows the other. Each
// LFO's overview shows the other LFO, so both are visible.
function lfoLayer(n: 0 | 1): Layout['layers'][number] {
  const lfo = `lfo[${n}]`, other = `lfo[${1 - n}]`;
  return {
    id: `lfo${n + 1}`, label: `LFO ${n + 1}`, button: 'bLfo',
    assign: {
      e1: { param: `${lfo}.rate`, range: { min: 0.05, max: 20 }, taper: 'exponential', detents: 60 },
      e2: {
        param: `${lfo}.depth`, taper: 'bipolarSquare', detents: 64,
        range: { min: -48, max: 48 },
        rangeBy: {
          pitch: { min: -12, max: 12 },          // vibrato to an octave, fine near zero
          cutoff: { min: -48, max: 48 },
          pulse_width: { min: -50, max: 50 },
          resonance: { min: -5.5, max: 5.5 },
        },
      },
      e3: { param: `${lfo}.destination` },
      e4: { param: `${lfo}.shape` },
    },
    overview: {
      tiles: [`${other}.rate`, `${other}.depth`, `${other}.destination`, `${other}.shape`],
      graphic: 'none',
    },
  };
}
