// library.ts — the presets on this device: the factory presets the app
// carries, and the user's own
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The library mirrors the synth's storage layout (docs/storage_format.md
// "Layout"): Presets/Factory/<Category>/<Name>.toml, and the same under
// Presets/User. Factory presets come from the firmware tree (generated
// into factoryPresets.ts) and are read-only. User presets live in a
// PresetStorage: app files on Android, browser storage on the web, memory
// in tests. No server, no account: a preset is a portable .toml file.
//
// Pure TypeScript: no React or native imports.

import { FACTORY_FILES } from '../generated/factoryPresets';

export type PresetSource = 'factory' | 'user';

export interface LibraryEntry {
  readonly source: PresetSource;
  readonly category: string;
  readonly name: string;
  // Below the synth's /storage: Presets/<Factory|User>/<Category>/<Name>.toml
  readonly path: string;
}

const PRESET_PATH = /^Presets\/(Factory|User)\/([^/]+)\/([^/]+)\.toml$/;

export function presetPath(source: PresetSource, category: string, name: string): string {
  return `Presets/${source === 'factory' ? 'Factory' : 'User'}/${category}/${name}.toml`;
}

// The entry for a path in the layout, or undefined for any other path
// (system.toml, banks.toml, a file outside a category folder).
export function entryOf(path: string): LibraryEntry | undefined {
  const m = PRESET_PATH.exec(path);
  if (!m) return undefined;
  return { source: m[1] === 'Factory' ? 'factory' : 'user', category: m[2]!, name: m[3]!, path };
}

export function byCategoryThenName(a: LibraryEntry, b: LibraryEntry): number {
  return a.category.localeCompare(b.category) || a.name.localeCompare(b.name);
}

export function factoryEntries(): LibraryEntry[] {
  return Object.keys(FACTORY_FILES).map(entryOf)
    .filter((e): e is LibraryEntry => e?.source === 'factory')
    .sort(byCategoryThenName);
}

export function factoryText(entry: LibraryEntry): string {
  const text = FACTORY_FILES[entry.path];
  if (entry.source !== 'factory' || text === undefined) throw new Error(`no factory preset ${entry.path}`);
  return text;
}

// The startup preset system.toml names, if it is a factory preset.
export function startupEntry(): LibraryEntry | undefined {
  const m = /^\s*startup_preset\s*=\s*"([^"]+)"/m.exec(FACTORY_FILES['system.toml'] ?? '');
  const entry = m ? entryOf(m[1]!) : undefined;
  return entry?.source === 'factory' ? entry : undefined;
}

// Where user presets are kept. Writes only ever go under Presets/User.
export interface PresetStorage {
  list(): Promise<LibraryEntry[]>;
  read(entry: LibraryEntry): Promise<string>;
  // Write the user preset, replacing one with the same category and name.
  write(category: string, name: string, text: string): Promise<LibraryEntry>;
  exists(category: string, name: string): Promise<boolean>;
  remove(entry: LibraryEntry): Promise<void>;
}

// User presets in memory: for tests, and the fallback where nothing else
// is available.
export class MemoryStorage implements PresetStorage {
  private readonly files = new Map<string, string>();

  async list(): Promise<LibraryEntry[]> {
    return [...this.files.keys()].map((p) => entryOf(p)!).sort(byCategoryThenName);
  }

  async read(entry: LibraryEntry): Promise<string> {
    const text = this.files.get(entry.path);
    if (text === undefined) throw new Error(`no user preset ${entry.path}`);
    return text;
  }

  async write(category: string, name: string, text: string): Promise<LibraryEntry> {
    const path = presetPath('user', category, name);
    // FAT compares names case-insensitively: a name that differs only in
    // case replaces the other
    for (const existing of this.files.keys())
      if (existing.toLowerCase() === path.toLowerCase()) this.files.delete(existing);
    this.files.set(path, text);
    return entryOf(path)!;
  }

  async exists(category: string, name: string): Promise<boolean> {
    const path = presetPath('user', category, name).toLowerCase();
    return [...this.files.keys()].some((p) => p.toLowerCase() === path);
  }

  async remove(entry: LibraryEntry): Promise<void> {
    this.files.delete(entry.path);
  }
}
