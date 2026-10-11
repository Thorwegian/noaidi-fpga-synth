// LayerButton.tsx — a virtual panel button with a lit indicator
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { Pressable, StyleSheet, Text, View } from 'react-native';

interface Props {
  readonly label: string;
  readonly active: boolean;
  readonly onPress: () => void;
}

export function LayerButton({ label, active, onPress }: Props) {
  return (
    <View style={styles.wrap}>
      <View style={[styles.led, active && styles.ledOn]} />
      <Pressable onPress={onPress}
                 style={({ pressed }) => [styles.button, pressed && styles.pressed]}>
        <Text style={[styles.text, active && styles.textOn]}>{label}</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignItems: 'center' },
  led: { width: 18, height: 5, borderRadius: 2, backgroundColor: '#2a2016', marginBottom: 6 },
  ledOn: { backgroundColor: '#f0a020', shadowColor: '#f0a020', shadowOpacity: 0.9, shadowRadius: 6, elevation: 6 },
  button: {
    minWidth: 84, paddingVertical: 12, paddingHorizontal: 10, borderRadius: 5,
    backgroundColor: '#2b2f36', borderWidth: 1, borderColor: '#4a515c', alignItems: 'center',
  },
  pressed: { backgroundColor: '#3a404a' },
  text: { color: '#8a96a3', fontWeight: '700', fontSize: 12, letterSpacing: 1 },
  textOn: { color: '#f0c070' },
});
