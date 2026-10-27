// session.ts — the preset being worked on: one preset store shared by the
// Library, the Editor and the Panel, and where that preset came from
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Opening a preset (from the library or a file) replaces the store's
// preset, so every view follows at once. Saving rules:
// - Save writes back to the user preset it came from;
// - a factory preset, an imported file or a new preset needs Save As,
//   which writes a user preset: factory presets are never written;
// - a file whose format is newer than the companion's is read-only: no
//   Save, Save As or Export, since its keys may mean something else.
//
// Pure TypeScript: no React or native imports.

import { readPresetFile, writePresetFile } from '../core/presetFile';
import type { Preset } from '../core/preset';
import { createPresetStore, type PresetStore } from '../core/presetStore';
import { PRESET_CATEGORIES } from '../generated/factoryPresets';
import { factoryText, type LibraryEntry, type PresetStorage } from './library';
import { presetNameProblem } from './presetName';

export interface PresetDocument {
  readonly name: string;
  readonly entry?: LibraryEntry;   // the library preset it is, if any
  readonly readOnly: boolean;
  readonly warnings: readonly string[];
  readonly dirty: boolean;         // edited since opened or saved
}

export class SaveError extends Error {}

// Save As found a user preset with that category and name.
export class ExistsError extends SaveError {}

export type DocumentListener = (doc: PresetDocument) => void;

export class PresetSession {
  readonly store: PresetStore;
  private doc: PresetDocument;
  private opening = false;
  private readonly listeners = new Set<DocumentListener>();

  constructor(private readonly storage: PresetStorage, initial: Preset, name: string, entry?: LibraryEntry) {
    this.store = createPresetStore(initial);
    this.doc = { name, entry, readOnly: false, warnings: [], dirty: false };
    this.store.subscribe(() => {
      if (!this.opening && !this.doc.dirty) this.update({ dirty: true });
    });
  }

  get document(): PresetDocument { return this.doc; }

  subscribe(listener: DocumentListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // Open preset text. Throws PresetFileError for a file the synth would
  // not read either.
  openText(text: string, name: string, entry?: LibraryEntry): void {
    const read = readPresetFile(text);
    this.opening = true;
    try { this.store.replace(read.preset); } finally { this.opening = false; }
    this.doc = { name, entry, readOnly: read.readOnly, warnings: read.warnings, dirty: false };
    this.notify();
  }

  async openEntry(entry: LibraryEntry): Promise<void> {
    const text = entry.source === 'factory' ? factoryText(entry) : await this.storage.read(entry);
    this.openText(text, entry.name, entry);
  }

  canSave(): boolean {
    return !this.doc.readOnly && this.doc.entry?.source === 'user';
  }

  canSaveAs(): boolean {
    return !this.doc.readOnly;
  }

  // The preset as a format-1 file.
  exportText(): string {
    if (this.doc.readOnly) throw new SaveError('a preset from a newer format is read-only');
    return writePresetFile(this.store.getPreset());
  }

  async save(): Promise<LibraryEntry> {
    const entry = this.doc.entry;
    if (!this.canSave() || !entry) throw new SaveError('only a user preset can be saved in place: use Save As');
    const saved = await this.storage.write(entry.category, entry.name, this.exportText());
    this.update({ entry: saved, dirty: false });
    return saved;
  }

  // Save as a user preset. Throws SaveError for a bad name or category,
  // ExistsError when that user preset exists and overwrite is not set.
  async saveAs(category: string, name: string, overwrite = false): Promise<LibraryEntry> {
    const problem = presetNameProblem(name) ?? categoryProblem(category);
    if (problem) throw new SaveError(problem);
    const text = this.exportText();
    if (!overwrite && await this.storage.exists(category, name))
      throw new ExistsError(`a user preset ${category}/${name} exists`);
    const saved = await this.storage.write(category, name, text);
    this.update({ name, entry: saved, dirty: false });
    return saved;
  }

  private update(change: Partial<PresetDocument>): void {
    this.doc = { ...this.doc, ...change };
    this.notify();
  }

  private notify(): void {
    for (const l of this.listeners) l(this.doc);
  }
}

// A category is a folder name: the firmware's, or one a user added (the
// same rules as a preset name).
function categoryProblem(category: string): string | null {
  if (PRESET_CATEGORIES.includes(category)) return null;
  const problem = presetNameProblem(category);
  return problem ? `category: ${problem}` : null;
}
