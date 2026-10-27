// App.tsx — the companion: Library, Editor and Panel, three views of one
// current preset
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// src/companion.ts wires the parts (one preset session, MockTransport, the
// Layout A panel); React draws them. All three views stay mounted, so the
// Panel's LVGL display keeps running while another view is shown.

import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { createCompanion } from '../companion';
import { MockTransport } from '../core/transport';
import { display } from '../display/parameters';
import { PRESET_CATEGORIES } from '../generated/factoryPresets';
import { layoutA } from '../layouts/layoutA';
import { factoryEntries, type LibraryEntry } from '../library/library';
import { ExistsError, SaveError } from '../library/session';
import { connectDisplay, type FromDisplay } from '../simulator/displayBridge';
import type { DisplayHandle } from './components/LvglDisplay';
import { Panel } from './components/Panel';
import { EditorView } from './editor/EditorView';
import { LibraryView } from './library/LibraryView';
import { SaveAsDialog } from './library/SaveAsDialog';
import { createStorage, exportPresetFile, importPresetFile } from './platform/files';

type Tab = 'library' | 'editor' | 'panel';
const TABS: { id: Tab; label: string }[] = [
  { id: 'library', label: 'Library' }, { id: 'editor', label: 'Editor' }, { id: 'panel', label: 'Panel' },
];
const REFRESH_MS = { 30: 33, 60: 16 } as const;
const FACTORY = factoryEntries();

// On the web, ?tab=editor (or panel) opens that view: for screenshots
// and links during development.
function initialTab(): Tab {
  if (Platform.OS !== 'web') return 'library';
  const t = new URLSearchParams(window.location.search).get('tab');
  return TABS.some((x) => x.id === t) ? (t as Tab) : 'library';
}

export default function App() {
  const storage = useMemo(() => createStorage(), []);
  const companion = useMemo(() => createCompanion(storage, layoutA), [storage]);
  const { session, panel, transport } = companion;
  const store = session.store;

  const [tab, setTab] = useState<Tab>(initialTab);
  const [userEntries, setUserEntries] = useState<LibraryEntry[]>([]);
  const [status, setStatus] = useState<string | null>(null);
  const [saveAs, setSaveAs] = useState(false);
  const [fps, setFps] = useState<number | null>(null);
  const [rate, setRate] = useState<30 | 60>(30);
  const [showValues, setShowValues] = useState(false);
  const [, redraw] = useReducer((n: number) => n + 1, 0);
  const screen = useRef<DisplayHandle>(null);

  const refreshUser = useCallback(() => { storage.list().then(setUserEntries, () => setUserEntries([])); }, [storage]);
  useEffect(refreshUser, [refreshUser]);
  useEffect(() => store.subscribe(redraw), [store]);
  useEffect(() => session.subscribe(redraw), [session]);
  useEffect(() => panel.surface.subscribe(redraw), [panel]);
  useEffect(() => {
    const timer = setInterval(() => panel.tick(), 100);
    return () => clearInterval(timer);
  }, [panel]);
  const bridge = useMemo(() => connectDisplay(store, panel.surface, (m) => screen.current?.post(m)), [store, panel]);
  useEffect(() => () => { bridge.dispose(); companion.dispose(); }, [bridge, companion]);
  useEffect(() => { screen.current?.post({ type: 'refresh', ms: REFRESH_MS[rate] }); }, [rate]);

  const say = (text: string) => { setStatus(text); setTimeout(() => setStatus((s) => (s === text ? null : s)), 4000); };
  const fail = (e: unknown) => say(e instanceof Error ? e.message : String(e));

  const onDisplayMessage = (m: FromDisplay) => {
    if (m.type === 'fps') setFps(m.fps);
    if (m.type === 'ready') screen.current?.post({ type: 'refresh', ms: REFRESH_MS[rate] });
    bridge.receive(m);
  };

  const open = (entry: LibraryEntry) => { session.openEntry(entry).then(() => say(`Opened ${entry.name}`), fail); };
  const importFile = async () => {
    try {
      const file = await importPresetFile();
      if (!file) return;
      session.openText(file.text, file.name);
      say(session.document.readOnly ? `${file.name}: a newer format, opened read-only` : `Imported ${file.name}`);
      setTab('editor');
    } catch (e) { fail(e); }
  };
  const save = async () => {
    try { await session.save(); refreshUser(); say(`Saved ${session.document.name}`); } catch (e) { fail(e); }
  };
  const exportFile = async () => {
    try {
      const where = await exportPresetFile(session.document.name, session.exportText());
      if (where) say(`Exported ${session.document.name}.toml to ${where}`);
    } catch (e) { fail(e); }
  };
  const saveAsResult = async (category: string, name: string, overwrite: boolean) => {
    try {
      await session.saveAs(category, name, overwrite);
      refreshUser();
      setSaveAs(false);
      say(`Saved ${category}/${name}`);
      return null;
    } catch (e) {
      if (e instanceof ExistsError) return 'exists' as const;
      if (e instanceof SaveError) return e.message;
      return String(e);
    }
  };

  const doc = session.document;
  const focus = panel.surface.getState().focus;
  const last = transport instanceof MockTransport ? transport.calls[transport.calls.length - 1] : undefined;
  const source = doc.entry ? (doc.entry.source === 'factory' ? 'Factory' : 'User') : 'File';

  return (
    <View style={styles.root}>
      <View style={styles.header}>
        <Text style={styles.brand}>NOAIDI</Text>
        <View style={styles.tabs} accessibilityRole="tablist">
          {TABS.map((t) => (
            <Pressable key={t.id} onPress={() => setTab(t.id)} style={[styles.tab, tab === t.id && styles.tabOn]}
                       accessibilityRole="tab" accessibilityState={{ selected: tab === t.id }}>
              <Text style={[styles.tabText, tab === t.id && styles.tabTextOn]}>{t.label}</Text>
            </Pressable>
          ))}
        </View>
        <View style={styles.doc}>
          <Text style={styles.docName} numberOfLines={1}>{doc.name}{doc.dirty ? ' •' : ''}</Text>
          <Text style={styles.docSource}>{doc.entry ? `${source} · ${doc.entry.category}` : source}{doc.readOnly ? ' · read-only' : ''}</Text>
        </View>
        <View style={styles.actions}>
          <Action label="Undo" onPress={() => store.undo()} disabled={!store.canUndo()} />
          <Action label="Redo" onPress={() => store.redo()} disabled={!store.canRedo()} />
          <Action label="Save" onPress={save} disabled={!session.canSave() || !doc.dirty} />
          <Action label="Save As…" onPress={() => setSaveAs(true)} disabled={!session.canSaveAs()} />
          <Action label="Export" onPress={exportFile} disabled={doc.readOnly} />
        </View>
      </View>
      {status && <Text style={styles.status} accessibilityLiveRegion="polite">{status}</Text>}
      {doc.warnings.length > 0 && (
        <Text style={styles.warning} numberOfLines={2}>{doc.warnings.join(' · ')}</Text>
      )}

      <View style={[styles.view, tab !== 'library' && styles.hidden]}>
        <LibraryView factory={FACTORY} user={userEntries} current={doc.entry} onOpen={open} onImport={importFile} />
      </View>
      <View style={[styles.view, tab !== 'editor' && styles.hidden]}>
        <EditorView store={store} />
      </View>
      <View style={[styles.view, tab !== 'panel' && styles.hidden]}>
        <Panel ref={screen} layout={layoutA} panel={panel} store={store} showValues={showValues}
               onDisplayMessage={onDisplayMessage} />
        <View style={styles.diag}>
          <Text style={styles.diagText}>{layoutA.name}</Text>
          <Text style={styles.diagText}>Focus: {focus ? display(focus.param).label : 'overview'}</Text>
          <Text style={styles.diagText} numberOfLines={1}>
            Mock synth: {last?.op === 'setParameter' ? `${last.id} = ${String(last.value)}` : last?.op ?? '-'}
          </Text>
          <Text style={styles.diagText}>Display: {fps === null ? 'starting' : `${fps} frames/s drawn`}</Text>
          <Pressable onPress={() => setRate(rate === 30 ? 60 : 30)}><Text style={styles.toggle}>Cap {rate} fps</Text></Pressable>
          <Pressable onPress={() => setShowValues(!showValues)}><Text style={styles.toggle}>Values {showValues ? 'on' : 'off'}</Text></Pressable>
        </View>
      </View>

      <SaveAsDialog visible={saveAs} onClose={() => setSaveAs(false)} onSave={saveAsResult}
                    initialName={doc.name}
                    initialCategory={doc.entry?.category ?? PRESET_CATEGORIES[0]!} />
    </View>
  );
}

function Action({ label, onPress, disabled }: { label: string; onPress: () => void; disabled?: boolean }) {
  return (
    <Pressable onPress={onPress} disabled={disabled} style={[styles.action, disabled && styles.actionOff]}
               accessibilityRole="button" accessibilityState={{ disabled }}>
      <Text style={styles.actionText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#14171c', paddingHorizontal: 20, paddingTop: 14, paddingBottom: 6 },
  header: { flexDirection: 'row', alignItems: 'center', gap: 16, marginBottom: 10 },
  brand: { color: '#f0a020', fontWeight: '800', letterSpacing: 3, fontSize: 15 },
  tabs: { flexDirection: 'row', gap: 4 },
  tab: { minHeight: 44, paddingHorizontal: 18, justifyContent: 'center', borderRadius: 6 },
  tabOn: { backgroundColor: '#2b2f36' },
  tabText: { color: '#a8b0ba', fontSize: 15, fontWeight: '600' },
  tabTextOn: { color: '#f0c070' },
  doc: { flex: 1, alignItems: 'flex-end' },
  docName: { color: '#e8e8e8', fontSize: 16, fontWeight: '700' },
  docSource: { color: '#8a96a3', fontSize: 12 },
  actions: { flexDirection: 'row', gap: 6 },
  action: { minHeight: 44, paddingHorizontal: 12, justifyContent: 'center', borderRadius: 6, borderWidth: 1, borderColor: '#3a3f47' },
  actionOff: { opacity: 0.35 },
  actionText: { color: '#e8e8e8', fontSize: 14 },
  status: { color: '#14171c', backgroundColor: '#f0c070', alignSelf: 'flex-end', paddingHorizontal: 10, paddingVertical: 4, borderRadius: 4, marginBottom: 6, fontSize: 13 },
  warning: { color: '#e0a050', fontSize: 12, marginBottom: 6 },
  view: { flex: 1 },
  hidden: { display: 'none' },
  diag: { flexDirection: 'row', alignItems: 'center', gap: 18, paddingTop: 6 },
  diagText: { color: '#8a96a3', fontSize: 11 },
  toggle: { color: '#a8b0ba', fontSize: 11, borderWidth: 1, borderColor: '#3a3f47', borderRadius: 4, paddingHorizontal: 8, paddingVertical: 3 },
});
