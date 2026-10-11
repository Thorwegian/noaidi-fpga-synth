// Knob.tsx — a virtual rotary pot: drag up or down to turn it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Absolute: its position is the parameter's place in the panel range, as
// a pot (or a motorised fader) would show. Touching it counts as touching
// the hardware control: it focuses the parameter before any movement.

import { useRef } from 'react';
import { PanResponder, StyleSheet, Text, View } from 'react-native';

const TRAVEL_PX = 220;   // vertical drag for the full travel
const SWEEP_DEG = 270;

interface Props {
  readonly label: string;
  readonly position: number;          // 0 … 1
  readonly valueText: string;
  readonly onTouch: () => void;
  readonly onMove: (position: number) => void;
}

export function Knob({ label, position, valueText, onTouch, onMove }: Props) {
  const latest = useRef({ position, onTouch, onMove });
  latest.current = { position, onTouch, onMove };
  const start = useRef(0);

  const responder = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: () => {
      start.current = latest.current.position;
      latest.current.onTouch();
    },
    onPanResponderMove: (_, g) => {
      const p = Math.min(Math.max(start.current - g.dy / TRAVEL_PX, 0), 1);
      latest.current.onMove(p);
    },
    onPanResponderTerminationRequest: () => false,
  })).current;

  const angle = -SWEEP_DEG / 2 + position * SWEEP_DEG;
  return (
    <View style={styles.wrap}>
      <View style={styles.knob} {...responder.panHandlers}>
        <View style={[styles.pointerArm, { transform: [{ rotate: `${angle}deg` }] }]}>
          <View style={styles.pointer} />
        </View>
      </View>
      <Text style={styles.label}>{label}</Text>
      <Text style={styles.value}>{valueText}</Text>
    </View>
  );
}

const SIZE = 112;
const styles = StyleSheet.create({
  wrap: { alignItems: 'center', margin: 12 },
  knob: {
    width: SIZE, height: SIZE, borderRadius: SIZE / 2, backgroundColor: '#2b2f36',
    borderWidth: 3, borderColor: '#454b55', alignItems: 'center', justifyContent: 'center',
  },
  pointerArm: { width: SIZE, height: SIZE, alignItems: 'center' },
  pointer: { width: 6, height: SIZE / 2 - 10, marginTop: 8, borderRadius: 3, backgroundColor: '#f0a020' },
  label: { color: '#c8ccd2', marginTop: 8, fontSize: 15, fontWeight: '600' },
  value: { color: '#8a96a3', fontSize: 13, marginTop: 2 },
});
