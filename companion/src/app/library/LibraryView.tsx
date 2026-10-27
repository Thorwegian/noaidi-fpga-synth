// LibraryView.tsx — the presets on this device, by source and category;
// choosing one opens it in the shared preset store
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import type { LibraryEntry } from '../../library/library';

interface Props {
  readonly factory: readonly LibraryEntry[];
  readonly user: readonly LibraryEntry[];
  readonly current?: LibraryEntry;
  readonly onOpen: (entry: LibraryEntry) => void;
  readonly onImport: () => void;
}

function groups(entries: readonly LibraryEntry[]): [string, LibraryEntry[]][] {
  const byCategory = new Map<string, LibraryEntry[]>();
  for (const e of entries) {
    if (!byCategory.has(e.category)) byCategory.set(e.category, []);
    byCategory.get(e.category)!.push(e);
  }
  return [...byCategory];
}

export function LibraryView({ factory, user, current, onOpen, onImport }: Props) {
  const column = (title: string, entries: readonly LibraryEntry[], empty: string) => (
    <View style={styles.column}>
      <Text style={styles.heading} accessibilityRole="header">{title}</Text>
      {entries.length === 0 && <Text style={styles.empty}>{empty}</Text>}
      {groups(entries).map(([category, list]) => (
        <View key={category} style={styles.group}>
          <Text style={styles.category}>{category}</Text>
          {list.map((e) => {
            const selected = current?.path === e.path;
            return (
              <Pressable key={e.path} onPress={() => onOpen(e)} style={[styles.item, selected && styles.itemOn]}
                         accessibilityRole="button" accessibilityState={{ selected }}
                         accessibilityLabel={`${e.name}, ${e.category}, ${e.source}`}>
                <Text style={[styles.name, selected && styles.nameOn]}>{e.name}</Text>
                <Text style={[styles.badge, e.source === 'factory' ? styles.factory : styles.user]}>
                  {e.source === 'factory' ? 'FACTORY' : 'USER'}
                </Text>
              </Pressable>
            );
          })}
        </View>
      ))}
    </View>
  );
  return (
    <ScrollView contentContainerStyle={styles.root}>
      {column('Factory', factory, 'No factory presets.')}
      <View style={styles.column}>
        {column('User', user, 'No user presets yet. Save As or import one.')}
        <Pressable onPress={onImport} style={styles.import} accessibilityRole="button">
          <Text style={styles.importText}>Import a .toml preset…</Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flexDirection: 'row', gap: 24, padding: 4 },
  column: { flex: 1, minWidth: 280 },
  heading: { color: '#f0a020', fontSize: 14, fontWeight: '700', letterSpacing: 1, marginBottom: 8, textTransform: 'uppercase' },
  empty: { color: '#8a96a3', fontSize: 13, marginBottom: 12 },
  group: { marginBottom: 14 },
  category: { color: '#8a96a3', fontSize: 12, fontWeight: '700', marginBottom: 4 },
  item: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', minHeight: 44,
    paddingHorizontal: 12, borderRadius: 6, backgroundColor: '#1a1d22', borderWidth: 1, borderColor: '#2c3138', marginBottom: 4,
  },
  itemOn: { borderColor: '#f0a020', backgroundColor: '#2a2214' },
  name: { color: '#e8e8e8', fontSize: 15 },
  nameOn: { fontWeight: '700' },
  badge: { fontSize: 10, fontWeight: '700', letterSpacing: 1, paddingHorizontal: 6, paddingVertical: 2, borderRadius: 3, overflow: 'hidden' },
  factory: { color: '#14171c', backgroundColor: '#8a96a3' },
  user: { color: '#14171c', backgroundColor: '#f0a020' },
  import: { marginTop: 8, minHeight: 44, justifyContent: 'center', paddingHorizontal: 12, borderRadius: 6, borderWidth: 1, borderColor: '#3a3f47', borderStyle: 'dashed' },
  importText: { color: '#c8ccd2', fontSize: 14 },
});
