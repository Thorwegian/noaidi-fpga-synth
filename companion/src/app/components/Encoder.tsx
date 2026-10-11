// Encoder.tsx — a virtual endless encoder: drag to turn it in detents
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Relative, with no label of its own: what it changes depends on the layer,
// and the screen above it says so. Up or right turns it clockwise.

import { useRef, useState } from 'react';
import { PanResponder, StyleSheet, View } from 'react-native';

const DETENT_PX = 14;    // drag per detent
const DETENT_DEG = 15;   // how far the cap turns per detent

interface Props {
  readonly onTouch: () => void;
  readonly onTurn: (steps: number) => void;
}

export function Encoder({ onTouch, onTurn }: Props) {
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

  return (
    <View style={styles.encoder} {...responder.panHandlers}>
      <View style={[styles.cap, { transform: [{ rotate: `${detents * DETENT_DEG}deg` }] }]}>
        <View style={styles.notch} />
      </View>
    </View>
  );
}

const SIZE = 72;
const styles = StyleSheet.create({
  encoder: {
    width: SIZE, height: SIZE, borderRadius: SIZE / 2, backgroundColor: '#1d2026',
    borderWidth: 2, borderColor: '#3a3f47', alignItems: 'center', justifyContent: 'center',
  },
  cap: { width: SIZE - 14, height: SIZE - 14, borderRadius: SIZE, backgroundColor: '#2f343c', alignItems: 'center' },
  notch: { width: 4, height: 14, marginTop: 4, borderRadius: 2, backgroundColor: '#c8ccd2' },
});
