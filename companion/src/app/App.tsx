// App.tsx — the LVGL/WASM spike: a simulated chassis around the real
// display
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// React draws the physical controls; the screen is the LVGL display. The
// sound lives in the patch store (loaded with the synth's configured
// startup patch), the control rules in the surface core, the link to a
// synth is MockTransport. React only wires these together and draws.

import { useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { parse } from 'smol-toml';

import { initPatch, type Patch } from '../core/patch';
import { readPatchFile } from '../core/patchFile';
import { createPatchStore } from '../core/patchStore';
import { MockTransport, linkStoreToTransport } from '../core/transport';
import { display } from '../display/parameters';
import { DISPLAY_HEIGHT, DISPLAY_WIDTH } from '../generated/displayHtml';
import { FACTORY_FILES } from '../generated/factoryPatches';
import { filterSpike } from '../layouts/filterSpike';
import { connectDisplay, type FromDisplay } from '../simulator/displayBridge';
import { createPanel } from '../simulator/panel';
import { Encoder } from './components/Encoder';
import { Knob } from './components/Knob';
import { LvglDisplay, type DisplayHandle } from './components/LvglDisplay';

// The sound the synth starts with: system.toml's startup_patch.
function startupPatch(): { patch: Patch; name: string } {
  try {
    const system = parse(FACTORY_FILES['system.toml'] ?? '') as { startup_patch?: string };
    const path = system.startup_patch ?? '';
    const text = FACTORY_FILES[path];
    if (text) return { patch: readPatchFile(text).patch, name: path.split('/').pop()!.replace(/\.toml$/, '') };
  } catch { /* fall through to the init patch */ }
  return { patch: initPatch(), name: 'Init' };
}

export default function App() {
  const { store, panel, transport, patchName } = useMemo(() => {
    const { patch, name } = startupPatch();
    const store = createPatchStore(patch);
    const transport = new MockTransport();
    linkStoreToTransport(store, transport);
    return { store, panel: createPanel(filterSpike, store), transport, patchName: name };
  }, []);

  const screen = useRef<DisplayHandle>(null);
  const [fps, setFps] = useState<number | null>(null);
  const [, redraw] = useReducer((n: number) => n + 1, 0);

  const bridge = useMemo(() => connectDisplay(store, panel.surface, (m) => screen.current?.post(m)),
                         [store, panel]);
  useEffect(() => () => bridge.dispose(), [bridge]);
  useEffect(() => store.subscribe(redraw), [store]);
  useEffect(() => panel.surface.subscribe(redraw), [panel]);
  useEffect(() => {
    const timer = setInterval(() => panel.tick(), 100);
    return () => clearInterval(timer);
  }, [panel]);

  const onDisplayMessage = (m: FromDisplay) => {
    if (m.type === 'fps') setFps(m.fps);
    bridge.receive(m);
  };

  const knob = (control: string) => {
    const param = filterSpike.fixed[control]!.param;
    return (
      <Knob
        label={display(param).shortLabel}
        position={panel.position(control)}
        valueText={display(param).format(store.get(param))}
        onTouch={() => panel.touch(control)}
        onMove={(p) => panel.move(control, p)}
      />
    );
  };

  const focus = panel.surface.getState().focus;
  const last = transport.calls[transport.calls.length - 1];

  return (
    <View style={styles.root}>
      <View style={styles.left}>
        <LvglDisplay ref={screen} style={styles.display} onMessage={onDisplayMessage} />
        <View style={styles.encoders}>
          {['e1', 'e2', 'e3', 'e4'].map((id) => (
            <Encoder key={id} onTouch={() => panel.touch(id)} onTurn={(s) => panel.turn(id, s)} />
          ))}
        </View>
      </View>
      <View style={styles.right}>
        <View style={styles.knobs}>
          {knob('cutoff')}
          {knob('resonance')}
        </View>
        <Pressable style={styles.button} onPress={() => panel.press('bFilter')}>
          <Text style={styles.buttonText}>FILTER</Text>
        </Pressable>
        <View style={styles.diag}>
          <Text style={styles.diagText}>Patch: {patchName}</Text>
          <Text style={styles.diagText}>Focus: {focus ? display(focus.param).label : 'overview'}</Text>
          <Text style={styles.diagText}>
            Mock synth: {last?.op === 'setParameter' ? `${last.id} = ${String(last.value)}` : last?.op ?? '-'}
          </Text>
          <Text style={styles.diagText}>Display: {fps === null ? 'starting' : `${fps} frames/s drawn`}</Text>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, flexDirection: 'row', backgroundColor: '#14171c', padding: 24 },
  left: { flex: 3, alignItems: 'center', justifyContent: 'center' },
  display: { width: '100%', aspectRatio: DISPLAY_WIDTH / DISPLAY_HEIGHT, maxHeight: '78%' },
  encoders: { flexDirection: 'row', justifyContent: 'space-around', width: '100%', marginTop: 16 },
  right: { flex: 2, alignItems: 'center', justifyContent: 'center' },
  knobs: { flexDirection: 'row' },
  button: {
    marginTop: 24, paddingHorizontal: 28, paddingVertical: 12, borderRadius: 6,
    backgroundColor: '#2b2f36', borderWidth: 2, borderColor: '#f0a020',
  },
  buttonText: { color: '#f0a020', fontWeight: '700', letterSpacing: 1 },
  diag: { marginTop: 32, alignSelf: 'stretch', paddingHorizontal: 16 },
  diagText: { color: '#6c7682', fontSize: 12, marginTop: 4 },
});
