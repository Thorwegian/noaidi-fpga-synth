// patchStore.ts — the patch being edited, shared by every view
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The Panel, the Editor and a transport read and change the same store,
// so they are views of one sound, not separate models. Listeners hear the
// IDs that changed, including dependents a change re-normalized.
//
// Undo keeps whole patches (they are immutable, so this is cheap). A
// knob drag sends many sets; pass { coalesce: true } so a run of sets to
// one parameter is one undo step.
//
// Pure TypeScript: no React or native imports.

import { changedIds, getValue, setValue, type Patch } from './patch';
import type { ParameterId, Value } from './parameters';

export type PatchListener = (patch: Patch, changed: readonly ParameterId[]) => void;

export interface SetOptions {
  readonly coalesce?: boolean;
}

export interface PatchStore {
  getPatch(): Patch;
  get(id: ParameterId): Value;
  // Throws RangeError for a value the parameter cannot hold.
  set(id: ParameterId, value: unknown, options?: SetOptions): void;
  // A new patch, e.g. one loaded from a file. One undo step.
  replace(patch: Patch): void;
  subscribe(listener: PatchListener): () => void;
  undo(): boolean;
  redo(): boolean;
  canUndo(): boolean;
  canRedo(): boolean;
}

const UNDO_DEPTH = 200;

export function createPatchStore(initial: Patch): PatchStore {
  let patch = initial;
  let undoStack: Patch[] = [];
  let redoStack: Patch[] = [];
  let coalescing: ParameterId | null = null;   // the parameter of an open run of sets
  const listeners = new Set<PatchListener>();

  function commit(next: Patch, record: boolean): void {
    const changed = changedIds(patch, next);
    if (record) {
      undoStack.push(patch);
      if (undoStack.length > UNDO_DEPTH) undoStack.shift();
      redoStack = [];
    }
    patch = next;
    for (const l of listeners) l(patch, changed);
  }

  return {
    getPatch: () => patch,
    get: (id) => getValue(patch, id),

    set(id, value, options) {
      const next = setValue(patch, id, value);
      const continues = options?.coalesce === true && coalescing === id;
      coalescing = options?.coalesce ? id : null;
      if (changedIds(patch, next).length === 0 && next.unresolved === patch.unresolved)
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
      redoStack.push(patch);
      coalescing = null;
      commit(prev, false);
      return true;
    },

    redo() {
      const next = redoStack.pop();
      if (!next) return false;
      undoStack.push(patch);
      coalescing = null;
      commit(next, false);
      return true;
    },

    canUndo: () => undoStack.length > 0,
    canRedo: () => redoStack.length > 0,
  };
}
