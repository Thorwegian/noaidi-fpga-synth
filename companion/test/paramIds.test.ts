// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The display's C parameter IDs (display/include/noaidi_param_ids.h) and
// the companion's (the manifest) are the same parameters in the same
// order: the bridge sends a parameter as its manifest index, and the C
// side reads it as a noaidi_param_t.

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

import { parameters } from '../src/core/parameters';
import { paramAt, paramIndex } from '../src/simulator/displayBridge';

const HEADER = readFileSync(new URL('../../display/include/noaidi_param_ids.h', import.meta.url), 'utf8');

describe('C and TypeScript parameter IDs', () => {
  const entries = [...HEADER.matchAll(/^\s+(NOAIDI_PARAM_\w+)\s+= (\d+),\s+\/\/ (\S+)$/gm)]
    .map((m) => ({ name: m[1]!, value: Number(m[2]), id: m[3]! }));

  it('list the same parameters in the same order', () => {
    expect(entries.map((e) => e.id)).toEqual(parameters.map((p) => p.id));
    entries.forEach((e, i) => expect(e.value).toBe(i));
    expect(HEADER).toMatch(new RegExp(`NOAIDI_PARAM_COUNT\\s*\\n} noaidi_param_t;`));
  });

  it('name each enum after its ID', () => {
    for (const e of entries)
      expect(e.name).toBe(`NOAIDI_PARAM_${e.id.replace(/[[\]]/g, '').replace(/\./g, '_').toUpperCase()}`);
    expect(entries.find((e) => e.id === 'filter.cutoff')?.name).toBe('NOAIDI_PARAM_FILTER_CUTOFF');
  });

  it('agree with the bridge', () => {
    for (const e of entries) {
      expect(paramIndex(e.id)).toBe(e.value);
      expect(paramAt(e.value)).toBe(e.id);
    }
  });
});
