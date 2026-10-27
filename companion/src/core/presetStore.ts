// presetStore.ts — the preset being edited, shared by every view
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The Panel, the Editor and a transport read and change the same store,
// so they are views of one sound, not separate models. Listeners hear the
// IDs that changed, including dependents a change re-normalized.
//
// Undo keeps whole presets (they are immutable, so this is cheap). A
// knob drag sends many sets; pass { coalesce: true } so a run of sets to
// one parameter is one undo step.
//
// Pure TypeScript: no React or native imports.

import { changedIds, getValue, setValue, type Preset } from './preset';
import type { ParameterId, Value } from './parameters';

export type PresetListener = (preset: Preset, changed: readonly ParameterId[]) => void;

export interface SetOptions {
  readonly coalesce?: boolean;
}

export interface PresetStore {
  getPreset(): Preset;
  get(id: ParameterId): Value;
  // Throws RangeError for a value the parameter cannot hold.
  set(id: ParameterId, value: unknown, options?: SetOptions): void;
  // A new preset, e.g. one loaded from a file. One undo step.
  replace(preset: Preset): void;
  subscribe(listener: PresetListener): () => void;
  undo(): boolean;
  redo(): boolean;
  canUndo(): boolean;
  canRedo(): boolean;
}

const UNDO_DEPTH = 200;

export function createPresetStore(initial: Preset): PresetStore {
  let preset = initial;
  let undoStack: Preset[] = [];
  let redoStack: Preset[] = [];
  let coalescing: ParameterId | null = null;   // the parameter of an open run of sets
  const listeners = new Set<PresetListener>();

  function commit(next: Preset, record: boolean): void {
    const changed = changedIds(preset, next);
    if (record) {
      undoStack.push(preset);
      if (undoStack.length > UNDO_DEPTH) undoStack.shift();
      redoStack = [];
    }
    preset = next;
    for (const l of listeners) l(preset, changed);
  }

  return {
    getPreset: () => preset,
    get: (id) => getValue(preset, id),

    set(id, value, options) {
      const next = setValue(preset, id, value);
      const continues = options?.coalesce === true && coalescing === id;
      coalescing = options?.coalesce ? id : null;
      if (changedIds(preset, next).length === 0 && next.unresolved === preset.unresolved)
        return;
      commit(next, !continues);
    },

    replace(next) {
      coalescing = null;
      commit(next, true);
    },

    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },

    undo() {
      const prev = undoStack.pop();
      if (!prev) return false;
      redoStack.push(preset);
      coalescing = null;
      commit(prev, false);
      return true;
    },

    redo() {
      const next = redoStack.pop();
      if (!next) return false;
      undoStack.push(preset);
      coalescing = null;
      commit(next, false);
      return true;
    },

    canUndo: () => undoStack.length > 0,
    canRedo: () => redoStack.length > 0,
  };
}
