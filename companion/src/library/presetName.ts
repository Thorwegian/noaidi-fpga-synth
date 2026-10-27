// presetName.ts — whether a name is a valid preset name
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The rules of docs/storage_format.md "Names", as the firmware's
// preset_name_valid() applies them (test/compat.test.ts checks the two
// agree): UTF-8, 1 to 64 characters; none of \ / : * ? " < > | and no
// control characters; no leading or trailing space, no trailing dot.
//
// Pure TypeScript: no React or native imports.

const FORBIDDEN = /[\\/:*?"<>|\u0000-\u001f\u007f]/u;
export const PRESET_NAME_MAX = 64;

export function presetNameProblem(name: string): string | null {
  const length = [...name].length;   // characters, not UTF-16 units
  if (length < 1) return 'a name needs at least one character';
  if (length > PRESET_NAME_MAX) return `at most ${PRESET_NAME_MAX} characters`;
  if (FORBIDDEN.test(name)) return 'none of \\ / : * ? " < > | or control characters';
  if (name.startsWith(' ') || name.endsWith(' ')) return 'no space at the start or end';
  if (name.endsWith('.')) return 'no dot at the end';
  return null;
}

export function validPresetName(name: string): boolean {
  return presetNameProblem(name) === null;
}
