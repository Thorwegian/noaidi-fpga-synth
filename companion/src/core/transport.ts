// transport.ts — how the companion talks to a synth
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The app speaks semantic parameters (setParameter("filter.cutoff", 370));
// how that reaches the synth (MIDI CC, SysEx, the serial console, USB,
// BLE) is a transport's business and stays behind this interface.
// MockTransport stands in for a synth so the whole UI works without
// hardware.
//
// Pure TypeScript: no React or native imports.

import type { Preset } from './preset';
import type { PresetStore } from './presetStore';
import type { ParameterId, Value } from './parameters';

export type ParameterChangeListener = (id: ParameterId, value: Value) => void;

export interface Transport {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  // A live edit of the active sound.
  setParameter(id: ParameterId, value: Value): void;
  // Replace the active sound.
  sendPreset(preset: Preset): Promise<void>;
  // Changes made on the synth side (its own controls, another client).
  onParameterChanged(listener: ParameterChangeListener): () => void;
}

export type MockCall =
  | { readonly op: 'connect' | 'disconnect' }
  | { readonly op: 'setParameter'; readonly id: ParameterId; readonly value: Value }
  | { readonly op: 'sendPreset'; readonly preset: Preset };

// Records every call; simulateChange() plays a change from the synth side.
export class MockTransport implements Transport {
  readonly name = 'Mock';
  readonly calls: MockCall[] = [];
  private readonly listeners = new Set<ParameterChangeListener>();

  async connect(): Promise<void> { this.calls.push({ op: 'connect' }); }
  async disconnect(): Promise<void> { this.calls.push({ op: 'disconnect' }); }

  setParameter(id: ParameterId, value: Value): void {
    this.calls.push({ op: 'setParameter', id, value });
  }

  async sendPreset(preset: Preset): Promise<void> {
    this.calls.push({ op: 'sendPreset', preset });
  }

  onParameterChanged(listener: ParameterChangeListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  simulateChange(id: ParameterId, value: Value): void {
    for (const l of this.listeners) l(id, value);
  }
}

// Keep a store and a transport in step: store changes go to the synth,
// synth changes come into the store without being sent back.
export function linkStoreToTransport(store: PresetStore, transport: Transport): () => void {
  let fromSynth = false;
  const offStore = store.subscribe((preset, changed) => {
    if (fromSynth) return;
    for (const id of changed) transport.setParameter(id, preset.values[id]!);
  });
  const offSynth = transport.onParameterChanged((id, value) => {
    fromSynth = true;
    try { store.set(id, value); } finally { fromSynth = false; }
  });
  return () => { offStore(); offSynth(); };
}
