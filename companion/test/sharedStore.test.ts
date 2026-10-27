// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One preset, three views: the Library opens a preset, the Editor edits
// it, and the Panel (Layout A), the LVGL display bridge and the transport
// all follow the same store.

import { describe, expect, it } from 'vitest';

import { createCompanion } from '../src/companion';
import { MockTransport } from '../src/core/transport';
import { layoutA } from '../src/layouts/layoutA';
import { factoryEntries, MemoryStorage } from '../src/library/library';
import { connectDisplay, paramIndex, type ToDisplay } from '../src/simulator/displayBridge';

function setup() {
  const transport = new MockTransport();
  const c = createCompanion(new MemoryStorage(), layoutA, transport, () => 0);
  const toDisplay: ToDisplay[] = [];
  connectDisplay(c.session.store, c.panel.surface, (m) => toDisplay.push(m), () => 0);
  return { ...c, transport, toDisplay };
}

describe('one store for Library, Editor, Panel and display', () => {
  it('opens with the startup preset', () => {
    const { session } = setup();
    expect(session.document.name).toBe('Supersaw');
    expect(session.store.get('voice.structure')).toBe('7+1');
  });

  it('a library preset reaches the panel, the display and the synth', async () => {
    const { session, panel, transport, toDisplay } = setup();
    const before = panel.position('cutoff');
    await session.openEntry(factoryEntries().find((e) => e.name === 'PowerBass')!);
    expect(session.document.name).toBe('PowerBass');
    expect(panel.position('cutoff')).not.toBe(before);
    expect(toDisplay).toContainEqual({ type: 'value', param: paramIndex('filter.cutoff'), value: session.store.get('filter.cutoff') });
    expect(transport.calls).toContainEqual({ op: 'setParameter', id: 'filter.cutoff', value: session.store.get('filter.cutoff') });
  });

  it('an Editor edit moves the panel control, the display and the synth', () => {
    const { session, panel, transport, toDisplay } = setup();
    session.store.set('filter.cutoff', 2400);            // what the Editor's slider does
    expect(panel.position('cutoff')).toBeCloseTo(Math.log(2400 / 20) / Math.log(14388.3 / 20), 6);
    expect(toDisplay.at(-1)).toEqual({ type: 'value', param: paramIndex('filter.cutoff'), value: 2400 });
    expect(transport.calls.at(-1)).toEqual({ op: 'setParameter', id: 'filter.cutoff', value: 2400 });
  });

  it('a panel move shows in what the Editor reads', () => {
    const { session, panel } = setup();
    panel.move('release', 1);
    expect(session.store.get('amp_env.release')).toBeCloseTo(15, 0);
    expect(session.document.dirty).toBe(true);
  });
});
