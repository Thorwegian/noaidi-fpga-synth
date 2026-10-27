// EditorView.tsx — every stored parameter of the current preset, grouped
// by the synth's structure, over its whole engine range
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Sections and controls come from src/editor/editorModel.ts (the
// generated catalogue plus display metadata); edits go to the shared
// preset store as semantic values, so the Panel and the display follow.

import { ScrollView, StyleSheet, Text, View } from 'react-native';

import type { PresetStore } from '../../core/presetStore';
import { display } from '../../display/parameters';
import { editorControl, editorSections } from '../../editor/editorModel';
import { Choice, Slider, Stepper, ValueEntry } from './controls';

interface Props {
  readonly store: PresetStore;
}

const SECTIONS = editorSections();

export function EditorView({ store }: Props) {
  const preset = store.getPreset();
  return (
    <ScrollView contentContainerStyle={styles.grid}>
      {SECTIONS.map((section) => (
        <View key={section.title} style={styles.card}>
          <Text style={styles.title} accessibilityRole="header">{section.title}</Text>
          {section.params.map((id) => {
            const d = display(id, preset);
            const value = store.get(id);
            const control = editorControl(id, preset);
            const unresolved = id in preset.unresolved;
            return (
              <View key={id} style={styles.row}>
                <View style={styles.rowHead}>
                  <Text style={styles.label}>{d.shortLabel}</Text>
                  {control.kind !== 'choice' ? (
                    <ValueEntry text={d.format(value)} editable
                                special={control.kind === 'slider' ? control.special : []}
                                onSubmit={(v) => store.set(id, v)} />
                  ) : null}
                </View>
                {unresolved && <Text style={styles.warning}>The file's value is not understood; it is kept until you change this.</Text>}
                {control.kind === 'choice' && <Choice options={control.options} value={value} onChange={(v) => store.set(id, v)} />}
                {control.kind === 'stepper' && (
                  <Stepper value={value as number} min={control.min} max={control.max} step={control.step}
                           onChange={(v) => store.set(id, v)} />
                )}
                {control.kind === 'slider' && (
                  <Slider assignment={control.assignment} preset={preset} value={value as number}
                          bipolar={control.bipolar} label={d.label}
                          onChange={(v, done) => store.set(id, v, { coalesce: !done })} />
                )}
              </View>
            );
          })}
        </View>
      ))}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 12, padding: 4, paddingBottom: 24 },
  card: {
    flexGrow: 1, flexBasis: 300, maxWidth: 460, backgroundColor: '#1a1d22', borderRadius: 8,
    borderWidth: 1, borderColor: '#2c3138', padding: 12,
  },
  title: { color: '#f0a020', fontSize: 13, fontWeight: '700', letterSpacing: 1, marginBottom: 6, textTransform: 'uppercase' },
  row: { paddingVertical: 6 },
  rowHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 },
  label: { color: '#c8ccd2', fontSize: 13 },
  warning: { color: '#e0a050', fontSize: 11, marginBottom: 4 },
});
