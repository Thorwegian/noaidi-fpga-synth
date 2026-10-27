// files.web.ts — preset files in the browser: the user library in the
// browser's local storage, import through a file input, export as a
// download; see files.ts
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// For development on a computer: browser storage belongs to the browser
// profile, so export is how a preset leaves it.

import { MemoryStorage, presetPath, entryOf, byCategoryThenName, type LibraryEntry, type PresetStorage } from '../../library/library';

const KEY = 'noaidi.userPresets';   // path → text

class BrowserStorage implements PresetStorage {
  private load(): Record<string, string> {
    try { return JSON.parse(window.localStorage.getItem(KEY) ?? '{}'); } catch { return {}; }
  }

  private store(files: Record<string, string>): void {
    window.localStorage.setItem(KEY, JSON.stringify(files));
  }

  async list(): Promise<LibraryEntry[]> {
    return Object.keys(this.load()).map((p) => entryOf(p)).filter((e): e is LibraryEntry => !!e).sort(byCategoryThenName);
  }

  async read(entry: LibraryEntry): Promise<string> {
    const text = this.load()[entry.path];
    if (text === undefined) throw new Error(`no user preset ${entry.path}`);
    return text;
  }

  async write(category: string, name: string, text: string): Promise<LibraryEntry> {
    const files = this.load();
    const path = presetPath('user', category, name);
    for (const existing of Object.keys(files))
      if (existing.toLowerCase() === path.toLowerCase()) delete files[existing];
    files[path] = text;
    this.store(files);
    return entryOf(path)!;
  }

  async exists(category: string, name: string): Promise<boolean> {
    const path = presetPath('user', category, name).toLowerCase();
    return Object.keys(this.load()).some((p) => p.toLowerCase() === path);
  }

  async remove(entry: LibraryEntry): Promise<void> {
    const files = this.load();
    delete files[entry.path];
    this.store(files);
  }
}

export function createStorage(): PresetStorage {
  try {
    window.localStorage.getItem(KEY);
    return new BrowserStorage();
  } catch {
    return new MemoryStorage();   // storage blocked: presets last until reload
  }
}

export function importPresetFile(): Promise<{ name: string; text: string } | null> {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = '.toml,text/plain';
    input.onchange = async () => {
      const file = input.files?.[0];
      resolve(file ? { name: file.name.replace(/\.toml$/i, ''), text: await file.text() } : null);
    };
    input.oncancel = () => resolve(null);
    input.click();
  });
}

export async function exportPresetFile(name: string, text: string): Promise<string | null> {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/toml' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = `${name}.toml`;
  a.click();
  URL.revokeObjectURL(url);
  return 'Downloads';
}
