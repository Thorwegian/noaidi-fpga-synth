// Knob.tsx — a virtual rotary pot with a fixed travel and a printed scale
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Absolute: its pointer shows the parameter's place in the panel range,
// as a pot would. Turn it around its centre, or drag up and down
// (src/simulator/knobGesture.ts decides which, per drag). Touching it
// counts as touching the hardware control: it focuses the parameter.

import { useRef } from 'react';
import { PanResponder, StyleSheet, Text, View } from 'react-native';

import { DEFAULT_KNOB_GESTURE, KnobGesture } from '../../simulator/knobGesture';

const SWEEP_DEG = 270;
const TICKS = 11;

interface Props {
  readonly label: string;
  readonly size: number;
  readonly position: number;          // 0 … 1
  readonly valueText?: string;
  readonly onTouch: () => void;
  readonly onMove: (position: number) => void;
}

export function Knob({ label, size, position, valueText, onTouch, onMove }: Props) {
  const latest = useRef({ position, onTouch, onMove, size });
  latest.current = { position, onTouch, onMove, size };
  const gesture = useRef<KnobGesture | null>(null);
  const start = useRef({ x: 0, y: 0 });   // touch point, relative to the centre

  const responder = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => {
      const { size: s } = latest.current;
      start.current = { x: e.nativeEvent.locationX - s / 2, y: e.nativeEvent.locationY - s / 2 };
      gesture.current = new KnobGesture(start.current, latest.current.position,
                                        { ...DEFAULT_KNOB_GESTURE, radiusPx: s / 2 });
      latest.current.onTouch();
    },
    onPanResponderMove: (_, g) => {
      const p = gesture.current?.move({ x: start.current.x + g.dx, y: start.current.y + g.dy });
      if (p !== null && p !== undefined) latest.current.onMove(p);
    },
    onPanResponderRelease: () => { gesture.current = null; },
    onPanResponderTerminate: () => { gesture.current = null; },
    onPanResponderTerminationRequest: () => false,
  })).current;

  const angle = -SWEEP_DEG / 2 + position * SWEEP_DEG;
  const cap = size * 0.72;
  return (
    <View style={styles.wrap}>
      <View style={{ width: size, height: size }} {...responder.panHandlers}>
        {Array.from({ length: TICKS }, (_, i) => (
          <View key={i} pointerEvents="none"
                style={[StyleSheet.absoluteFill, styles.center,
                        { transform: [{ rotate: `${-SWEEP_DEG / 2 + (i * SWEEP_DEG) / (TICKS - 1)}deg` }] }]}>
            <View style={[styles.tick, { height: size * 0.08, marginBottom: size * 0.92 }]} />
          </View>
        ))}
        <View pointerEvents="none" style={[StyleSheet.absoluteFill, styles.center]}>
          <View style={[styles.cap, { width: cap, height: cap, borderRadius: cap / 2 }]}>
            <View style={[StyleSheet.absoluteFill, styles.center, { transform: [{ rotate: `${angle}deg` }] }]}>
              <View style={[styles.pointer, { height: cap * 0.42, marginBottom: cap * 0.46 }]} />
            </View>
          </View>
        </View>
      </View>
      <Text style={styles.label} numberOfLines={1}>{label}</Text>
      {valueText !== undefined && <Text style={styles.value} numberOfLines={1}>{valueText}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignItems: 'center' },
  center: { alignItems: 'center', justifyContent: 'center' },
  tick: { width: 2, borderRadius: 1, backgroundColor: '#59616d' },
  cap: {
    backgroundColor: '#2b2f36', borderWidth: 2, borderColor: '#4a515c',
    shadowColor: '#000', shadowOpacity: 0.6, shadowRadius: 4, shadowOffset: { width: 0, height: 2 }, elevation: 4,
  },
  pointer: { width: 4, borderRadius: 2, backgroundColor: '#f0a020' },
  label: { color: '#c8ccd2', marginTop: 4, fontSize: 12, fontWeight: '600', letterSpacing: 0.5 },
  value: { color: '#8a96a3', fontSize: 11, marginTop: 1 },
});
