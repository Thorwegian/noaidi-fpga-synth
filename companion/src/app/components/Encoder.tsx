// Encoder.tsx — a virtual endless encoder: drag to turn it in detents
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Relative and unlabelled, unlike a knob: no scale, no end stops, a
// knurled rim. What it changes depends on the layer, and the screen above
// it says so. Up or right turns it clockwise.

import { useRef, useState } from 'react';
import { PanResponder, StyleSheet, View } from 'react-native';

const DETENT_PX = 14;    // drag per detent
const DETENT_DEG = 15;   // how far the cap turns per detent
const KNURLS = 24;

interface Props {
  readonly size: number;
  readonly onTouch: () => void;
  readonly onTurn: (steps: number) => void;
}

export function Encoder({ size, onTouch, onTurn }: Props) {
  const latest = useRef({ onTouch, onTurn });
  latest.current = { onTouch, onTurn };
  const done = useRef(0);   // detents already sent in this drag
  const [detents, setDetents] = useState(0);

  const responder = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: () => {
      done.current = 0;
      latest.current.onTouch();
    },
    onPanResponderMove: (_, g) => {
      const total = Math.trunc((g.dx - g.dy) / DETENT_PX);
      const steps = total - done.current;
      if (steps !== 0) {
        done.current = total;
        setDetents((d) => d + steps);
        latest.current.onTurn(steps);
      }
    },
    onPanResponderTerminationRequest: () => false,
  })).current;

  const inner = size * 0.7;
  return (
    <View style={[styles.rim, { width: size, height: size, borderRadius: size / 2 }]} {...responder.panHandlers}>
      <View pointerEvents="none"
            style={[StyleSheet.absoluteFill, { transform: [{ rotate: `${detents * DETENT_DEG}deg` }] }]}>
        {Array.from({ length: KNURLS }, (_, i) => (
          <View key={i} style={[StyleSheet.absoluteFill, styles.center, { transform: [{ rotate: `${(i * 360) / KNURLS}deg` }] }]}>
            <View style={[styles.knurl, { height: size * 0.12, marginBottom: size * 0.86 }]} />
          </View>
        ))}
        <View style={[StyleSheet.absoluteFill, styles.center]}>
          <View style={[styles.cap, { width: inner, height: inner, borderRadius: inner / 2 }]}>
            <View style={styles.dot} />
          </View>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  rim: { backgroundColor: '#1a1d22', borderWidth: 1, borderColor: '#3a3f47' },
  center: { alignItems: 'center', justifyContent: 'center' },
  knurl: { width: 2, backgroundColor: '#454b55' },
  cap: { backgroundColor: '#262a31', alignItems: 'center', paddingTop: 5 },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#8a96a3' },
});
