// Fader.tsx — a virtual slide fader
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Absolute, like a knob: the cap sits at the parameter's place in the panel
// range, so recalled presets position it and a row of faders shows a
// shape at a glance. Dragging moves the cap relative to where it was (a
// touch never makes it jump). No motor is simulated.

import { useRef, useState } from 'react';
import { PanResponder, StyleSheet, Text, View } from 'react-native';

interface Props {
  readonly label: string;
  readonly position: number;      // 0 … 1, bottom to top
  readonly valueText?: string;
  readonly onTouch: () => void;
  readonly onMove: (position: number) => void;
}

const CAP_H = 30;

export function Fader({ label, position, valueText, onTouch, onMove }: Props) {
  const [track, setTrack] = useState(1);
  const latest = useRef({ position, onTouch, onMove, track });
  latest.current = { position, onTouch, onMove, track };
  const start = useRef(0);

  const responder = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: () => {
      start.current = latest.current.position;
      latest.current.onTouch();
    },
    onPanResponderMove: (_, g) => {
      const travel = Math.max(latest.current.track - CAP_H, 1);
      latest.current.onMove(Math.min(Math.max(start.current - g.dy / travel, 0), 1));
    },
    onPanResponderTerminationRequest: () => false,
  })).current;

  const travel = Math.max(track - CAP_H, 0);
  return (
    <View style={styles.wrap}>
      <View style={styles.trackArea} onLayout={(e) => setTrack(e.nativeEvent.layout.height)}
            {...responder.panHandlers}>
        <View pointerEvents="none" style={styles.slot} />
        <View pointerEvents="none" style={[styles.fill, { height: travel * position + CAP_H / 2 }]} />
        <View pointerEvents="none" style={[styles.cap, { bottom: travel * position }]}>
          <View style={styles.capLine} />
        </View>
      </View>
      <Text style={styles.label} numberOfLines={1}>{label}</Text>
      {valueText !== undefined && <Text style={styles.value} numberOfLines={1}>{valueText}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flex: 1, alignItems: 'center', alignSelf: 'stretch' },
  trackArea: { flex: 1, width: 56, alignItems: 'center' },
  slot: { position: 'absolute', top: CAP_H / 2, bottom: CAP_H / 2, width: 6, borderRadius: 3, backgroundColor: '#0b0d10' },
  fill: { position: 'absolute', bottom: 0, width: 6, borderRadius: 3, backgroundColor: '#f0a02066' },
  cap: {
    position: 'absolute', width: 44, height: CAP_H, borderRadius: 4, backgroundColor: '#3a404a',
    borderWidth: 1, borderColor: '#5a626e', alignItems: 'center', justifyContent: 'center',
    shadowColor: '#000', shadowOpacity: 0.6, shadowRadius: 3, shadowOffset: { width: 0, height: 2 }, elevation: 4,
  },
  capLine: { width: 36, height: 2, backgroundColor: '#f0a020' },
  label: { color: '#c8ccd2', marginTop: 6, fontSize: 12, fontWeight: '600', letterSpacing: 0.5 },
  value: { color: '#8a96a3', fontSize: 11, marginTop: 1 },
});
