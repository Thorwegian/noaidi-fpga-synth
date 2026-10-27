// SaveAsDialog.tsx — name and category for a new user preset
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The name rules are the synth's (src/library/presetName.ts); a user
// preset with the same name is replaced only after the player says so.

import { useState } from 'react';
import { Modal, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { PRESET_CATEGORIES } from '../../generated/factoryPresets';
import { presetNameProblem } from '../../library/presetName';

interface Props {
  readonly visible: boolean;
  readonly initialName: string;
  readonly initialCategory: string;
  // Resolves to an error to show, 'exists' to ask about replacing, or null when saved.
  readonly onSave: (category: string, name: string, overwrite: boolean) => Promise<string | 'exists' | null>;
  readonly onClose: () => void;
}

export function SaveAsDialog({ visible, initialName, initialCategory, onSave, onClose }: Props) {
  const [name, setName] = useState(initialName);
  const [category, setCategory] = useState(initialCategory);
  const [error, setError] = useState<string | null>(null);
  const [exists, setExists] = useState(false);
  const categories = PRESET_CATEGORIES.includes(initialCategory) ? PRESET_CATEGORIES : [...PRESET_CATEGORIES, initialCategory];
  const problem = presetNameProblem(name);

  const save = async (overwrite: boolean) => {
    const result = await onSave(category, name, overwrite);
    setExists(result === 'exists');
    setError(result === 'exists' ? `${category}/${name} exists in your presets.` : result);
  };

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}
           onShow={() => { setName(initialName); setCategory(initialCategory); setError(null); setExists(false); }}>
      <View style={styles.backdrop}>
        <View style={styles.dialog} accessibilityViewIsModal>
          <Text style={styles.title}>Save as a user preset</Text>
          <Text style={styles.label}>Name</Text>
          <TextInput style={styles.input} value={name} onChangeText={(t) => { setName(t); setExists(false); setError(null); }}
                     autoFocus maxLength={80} accessibilityLabel="Preset name" />
          {problem && name.length > 0 && <Text style={styles.error}>{problem}</Text>}
          <Text style={styles.label}>Category</Text>
          <View style={styles.categories}>
            {categories.map((c) => (
              <Pressable key={c} onPress={() => { setCategory(c); setExists(false); setError(null); }}
                         style={[styles.chip, c === category && styles.chipOn]}
                         accessibilityRole="radio" accessibilityState={{ selected: c === category }}>
                <Text style={[styles.chipText, c === category && styles.chipTextOn]}>{c}</Text>
              </Pressable>
            ))}
          </View>
          {error && <Text style={styles.error}>{error}</Text>}
          <View style={styles.buttons}>
            <Pressable onPress={onClose} style={styles.button}><Text style={styles.buttonText}>Cancel</Text></Pressable>
            {exists ? (
              <Pressable onPress={() => save(true)} style={[styles.button, styles.primary]}>
                <Text style={styles.primaryText}>Replace it</Text>
              </Pressable>
            ) : (
              <Pressable onPress={() => save(false)} disabled={problem !== null}
                         style={[styles.button, styles.primary, problem !== null && styles.disabled]}>
                <Text style={styles.primaryText}>Save</Text>
              </Pressable>
            )}
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: '#000a', alignItems: 'center', justifyContent: 'center' },
  dialog: { width: 520, maxWidth: '90%', backgroundColor: '#1a1d22', borderRadius: 10, padding: 20, borderWidth: 1, borderColor: '#3a3f47' },
  title: { color: '#e8e8e8', fontSize: 18, fontWeight: '700', marginBottom: 12 },
  label: { color: '#8a96a3', fontSize: 12, marginTop: 10, marginBottom: 4 },
  input: { color: '#e8e8e8', fontSize: 16, borderWidth: 1, borderColor: '#3a3f47', borderRadius: 6, paddingHorizontal: 10, paddingVertical: 8 },
  categories: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  chip: { paddingHorizontal: 10, paddingVertical: 8, borderRadius: 4, borderWidth: 1, borderColor: '#3a3f47' },
  chipOn: { backgroundColor: '#3a2a08', borderColor: '#f0a020' },
  chipText: { color: '#a8b0ba', fontSize: 13 },
  chipTextOn: { color: '#f0c070', fontWeight: '700' },
  error: { color: '#f08060', fontSize: 13, marginTop: 6 },
  buttons: { flexDirection: 'row', justifyContent: 'flex-end', gap: 10, marginTop: 18 },
  button: { minHeight: 44, paddingHorizontal: 18, justifyContent: 'center', borderRadius: 6, borderWidth: 1, borderColor: '#3a3f47' },
  buttonText: { color: '#c8ccd2', fontSize: 15 },
  primary: { backgroundColor: '#f0a020', borderColor: '#f0a020' },
  primaryText: { color: '#14171c', fontSize: 15, fontWeight: '700' },
  disabled: { opacity: 0.4 },
});
