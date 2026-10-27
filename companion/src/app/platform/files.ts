// files.ts — preset files on Android and iOS: the user library in the
// app's own storage, import and export through the system's file pickers
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The user library mirrors the synth's layout under the app's document
// folder: Presets/User/<Category>/<Name>.toml. Import opens a .toml the
// user picks anywhere the system offers (Downloads, a USB stick, Drive if
// they choose); export writes into a folder they pick. Nothing here
// needs a network. files.web.ts is the same for the browser.

import { Directory, File, Paths } from 'expo-file-system';

import { byCategoryThenName, entryOf, presetPath, type LibraryEntry, type PresetStorage } from '../../library/library';

const USER = ['Presets', 'User'];

class AppStorage implements PresetStorage {
  private userDir(category?: string): Directory {
    return category ? new Directory(Paths.document, ...USER, category) : new Directory(Paths.document, ...USER);
  }

  async list(): Promise<LibraryEntry[]> {
    const root = this.userDir();
    if (!root.exists) return [];
    const entries: LibraryEntry[] = [];
    for (const category of root.list())
      if (category instanceof Directory)
        for (const file of category.list())
          if (file instanceof File && file.name.endsWith('.toml')) {
            const entry = entryOf(presetPath('user', category.name, file.name.replace(/\.toml$/, '')));
            if (entry) entries.push(entry);
          }
    return entries.sort(byCategoryThenName);
  }

  async read(entry: LibraryEntry): Promise<string> {
    return new File(Paths.document, entry.path).text();
  }

  // The same name in another letter case is the same preset on the synth
  // (FAT), so it is replaced here too.
  private sameName(category: string, name: string): File | undefined {
    const dir = this.userDir(category);
    if (!dir.exists) return undefined;
    const wanted = `${name}.toml`.toLowerCase();
    return dir.list().find((f): f is File => f instanceof File && f.name.toLowerCase() === wanted);
  }

  async write(category: string, name: string, text: string): Promise<LibraryEntry> {
    const dir = this.userDir(category);
    dir.create({ intermediates: true, idempotent: true });
    this.sameName(category, name)?.delete();
    const file = new File(dir, `${name}.toml`);
    file.create();
    file.write(text);
    return entryOf(presetPath('user', category, name))!;
  }

  async exists(category: string, name: string): Promise<boolean> {
    return this.sameName(category, name) !== undefined;
  }

  async remove(entry: LibraryEntry): Promise<void> {
    const file = new File(Paths.document, entry.path);
    if (file.exists) file.delete();
  }
}

export function createStorage(): PresetStorage {
  return new AppStorage();
}

// A .toml the user picks; null if they cancel.
export async function importPresetFile(): Promise<{ name: string; text: string } | null> {
  const picked = await File.pickFileAsync({ mimeTypes: ['application/toml', 'text/plain', 'application/octet-stream', '*/*'] });
  if (picked.canceled) return null;
  const file = picked.result;
  return { name: file.name.replace(/\.toml$/i, ''), text: await file.text() };
}

// Write text as <name>.toml into a folder the user picks; the folder's
// name, or null if they cancel.
export async function exportPresetFile(name: string, text: string): Promise<string | null> {
  let dir: Directory;
  try {
    dir = await Directory.pickDirectoryAsync();
  } catch {
    return null;   // the picker was closed
  }
  const file = dir.createFile(`${name}.toml`, 'application/octet-stream');
  file.write(text);
  return dir.name;
}
