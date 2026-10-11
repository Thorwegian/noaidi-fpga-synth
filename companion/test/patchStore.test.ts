// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { describe, expect, it } from 'vitest';

import { initPatch } from '../src/core/patch';
import { createPatchStore } from '../src/core/patchStore';
import { MockTransport, linkStoreToTransport } from '../src/core/transport';

describe('patchStore', () => {
  it('sets, gets and tells listeners what changed', () => {
    const store = createPatchStore(initPatch());
    const heard: string[][] = [];
    store.subscribe((_, changed) => heard.push([...changed]));
    store.set('filter.cutoff', 1000);
    expect(store.get('filter.cutoff')).toBe(1000);
    expect(heard).toEqual([['filter.cutoff']]);
  });

  it('reports dependents a change re-normalized', () => {
    const store = createPatchStore(initPatch());
    store.set('lfo[0].destination', 'cutoff');
    store.set('lfo[0].depth', 100);
    const heard: string[][] = [];
    store.subscribe((_, changed) => heard.push([...changed]));
    store.set('lfo[0].destination', 'pitch');
    expect(store.get('lfo[0].depth')).toBe(48);
    expect(heard).toEqual([['lfo[0].destination', 'lfo[0].depth']]);
  });

  it('ignores a set that changes nothing', () => {
    const store = createPatchStore(initPatch());
    let calls = 0;
    store.subscribe(() => calls++);
    store.set('filter.cutoff', 1e9);   // clamps to the init value, the top
    expect(calls).toBe(0);
    expect(store.canUndo()).toBe(false);
  });

  it('throws for a value the parameter cannot hold', () => {
    const store = createPatchStore(initPatch());
    expect(() => store.set('osc[0].wave', 'noise')).toThrow(RangeError);
    expect(() => store.set('no.such', 1)).toThrow(RangeError);
  });

  it('undoes and redoes, one step per coalesced run', () => {
    const store = createPatchStore(initPatch());
    for (const v of [1000, 900, 800]) store.set('filter.cutoff', v, { coalesce: true });
    store.set('osc[0].tune', 7);
    expect(store.undo()).toBe(true);
    expect(store.get('osc[0].tune')).toBe(0);
    expect(store.get('filter.cutoff')).toBe(800);
    expect(store.undo()).toBe(true);
    expect(store.get('filter.cutoff')).toBe(initPatch().values['filter.cutoff']);
    expect(store.undo()).toBe(false);
    expect(store.redo()).toBe(true);
    expect(store.get('filter.cutoff')).toBe(800);
  });
});

describe('MockTransport', () => {
  it('carries store changes to the synth and synth changes to the store, without echo', async () => {
    const store = createPatchStore(initPatch());
    const synth = new MockTransport();
    await synth.connect();
    linkStoreToTransport(store, synth);
    store.set('filter.cutoff', 500);
    synth.simulateChange('osc[0].tune', 12);
    expect(store.get('osc[0].tune')).toBe(12);
    expect(synth.calls).toEqual([
      { op: 'connect' },
      { op: 'setParameter', id: 'filter.cutoff', value: 500 },
    ]);
  });
});
