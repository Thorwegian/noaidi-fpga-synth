// companion.ts — the app's parts, wired together: one preset session
// whose store the Library, the Editor, the Panel, the display bridge and
// the transport all share
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// React (src/app) draws these; the tests drive them directly.
//
// Pure TypeScript: no React or native imports.

import { initPreset } from './core/preset';
import { readPresetFile } from './core/presetFile';
import type { Layout } from './core/surface';
import { MockTransport, linkStoreToTransport, type Transport } from './core/transport';
import { factoryText, startupEntry, type PresetStorage } from './library/library';
import { PresetSession } from './library/session';
import { createPanel, type Panel } from './simulator/panel';

export interface Companion {
  readonly session: PresetSession;
  readonly transport: Transport;
  readonly panel: Panel;
  dispose(): void;
}

// Opens with the synth's startup preset (system.toml), or the init preset
// if there is none. The transport is MockTransport until a real one exists.
export function createCompanion(storage: PresetStorage, layout: Layout,
                                transport: Transport = new MockTransport(),
                                now: () => number = Date.now): Companion {
  const startup = startupEntry();
  const session = startup
    ? new PresetSession(storage, readPresetFile(factoryText(startup)).preset, startup.name, startup)
    : new PresetSession(storage, initPreset(), 'Init');
  const unlink = linkStoreToTransport(session.store, transport);
  return {
    session,
    transport,
    panel: createPanel(layout, session.store, now),
    dispose: unlink,
  };
}
