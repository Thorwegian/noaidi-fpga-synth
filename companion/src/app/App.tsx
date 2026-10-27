// App.tsx — Layout A: a simulated instrument around the real display
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// React draws the physical controls (Panel); the screen is the LVGL
// display. The sound lives in the preset store (loaded with the synth's
// configured startup preset), the control rules in the surface core, the
// link to a synth is MockTransport. React only wires these together.

import { useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { parse } from 'smol-toml';

import { initPreset, type Preset } from '../core/preset';
import { readPresetFile } from '../core/presetFile';
import { createPresetStore } from '../core/presetStore';
import { MockTransport, linkStoreToTransport } from '../core/transport';
import { display } from '../display/parameters';
import { FACTORY_FILES } from '../generated/factoryPresets';
import { layoutA } from '../layouts/layoutA';
import { connectDisplay, type FromDisplay } from '../simulator/displayBridge';
import { createPanel } from '../simulator/panel';
import type { DisplayHandle } from './components/LvglDisplay';
import { Panel } from './components/Panel';

const REFRESH_MS = { 30: 33, 60: 16 } as const;

// The sound the synth starts with: system.toml's startup_preset.
function startupPreset(): { preset: Preset; name: string } {
  try {
    const system = parse(FACTORY_FILES['system.toml'] ?? '') as { startup_preset?: string };
    const path = system.startup_preset ?? '';
    const text = FACTORY_FILES[path];
    if (text) return { preset: readPresetFile(text).preset, name: path.split('/').pop()!.replace(/\.toml$/, '') };
  } catch { /* fall through to the init preset */ }
  return { preset: initPreset(), name: 'Init' };
}

export default function App() {
  const { store, panel, transport, presetName } = useMemo(() => {
    const { preset, name } = startupPreset();
    const store = createPresetStore(preset);
    const transport = new MockTransport();
    linkStoreToTransport(store, transport);
    return { store, panel: createPanel(layoutA, store), transport, presetName: name };
  }, []);

  const screen = useRef<DisplayHandle>(null);
  const [fps, setFps] = useState<number | null>(null);
  const [rate, setRate] = useState<30 | 60>(30);
  const [showValues, setShowValues] = useState(false);
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
  useEffect(() => { screen.current?.post({ type: 'refresh', ms: REFRESH_MS[rate] }); }, [rate]);

  const onDisplayMessage = (m: FromDisplay) => {
    if (m.type === 'fps') setFps(m.fps);
    if (m.type === 'ready') screen.current?.post({ type: 'refresh', ms: REFRESH_MS[rate] });
    bridge.receive(m);
  };

  const focus = panel.surface.getState().focus;
  const last = transport.calls[transport.calls.length - 1];

  return (
    <View style={styles.root}>
      <Panel ref={screen} layout={layoutA} panel={panel} store={store} showValues={showValues}
             onDisplayMessage={onDisplayMessage} />
      <View style={styles.diag}>
        <Text style={styles.diagText}>{layoutA.name} · {presetName}</Text>
        <Text style={styles.diagText}>Focus: {focus ? display(focus.param).label : 'overview'}</Text>
        <Text style={styles.diagText} numberOfLines={1}>
          Mock synth: {last?.op === 'setParameter' ? `${last.id} = ${String(last.value)}` : last?.op ?? '-'}
        </Text>
        <Text style={styles.diagText}>Display: {fps === null ? 'starting' : `${fps} frames/s drawn`}</Text>
        <Pressable onPress={() => setRate(rate === 30 ? 60 : 30)}>
          <Text style={styles.toggle}>Cap {rate} fps</Text>
        </Pressable>
        <Pressable onPress={() => setShowValues(!showValues)}>
          <Text style={styles.toggle}>Values {showValues ? 'on' : 'off'}</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#14171c', paddingHorizontal: 20, paddingTop: 20, paddingBottom: 6 },
  diag: { flexDirection: 'row', alignItems: 'center', gap: 18, paddingTop: 6 },
  diagText: { color: '#5c6672', fontSize: 11 },
  toggle: { color: '#8a96a3', fontSize: 11, borderWidth: 1, borderColor: '#3a3f47', borderRadius: 4, paddingHorizontal: 8, paddingVertical: 3 },
});
