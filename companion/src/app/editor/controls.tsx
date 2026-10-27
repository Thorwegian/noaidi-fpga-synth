// controls.tsx — the Editor's generic controls: a slider over the whole
// engine range, segmented choices, a stepper, and a value you can type
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Software controls, not imitations of hardware (that is the Panel). A
// slider maps its travel through the editor model's taper; tapping the
// value opens an exact entry, for values the slider can't hit by hand.

import { useRef, useState } from 'react';
import { PanResponder, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { positionToValue, valueToPosition, type Assignment } from '../../core/surface';
import type { Preset } from '../../core/preset';
import type { ChoiceOption } from '../../editor/editorModel';
import type { Value } from '../../core/parameters';

const ACCENT = '#f0a020';

interface SliderProps {
  readonly assignment: Assignment;
  readonly preset: Preset;
  readonly value: number;
  readonly bipolar: boolean;
  readonly label: string;   // for screen readers
  readonly onChange: (value: number, done: boolean) => void;
}

export function Slider({ assignment, preset, value, bipolar, label, onChange }: SliderProps) {
  const [width, setWidth] = useState(1);
  const latest = useRef({ assignment, preset, onChange, width });
  latest.current = { assignment, preset, onChange, width };
  const startX = useRef(0);

  const emit = (x: number, done: boolean) => {
    const { assignment: a, preset: p, onChange: change, width: w } = latest.current;
    change(positionToValue(a, Math.min(Math.max(x / w, 0), 1), p), done);
  };
  const responder = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: (e) => { startX.current = e.nativeEvent.locationX; emit(startX.current, false); },
    onPanResponderMove: (_, g) => emit(startX.current + g.dx, false),
    onPanResponderRelease: (_, g) => emit(startX.current + g.dx, true),
    onPanResponderTerminationRequest: () => false,
  })).current;

  const finite = Number.isFinite(value);
  const pos = finite ? valueToPosition(assignment, value, preset) : value > 0 ? 1 : 0;
  const centre = bipolar ? valueToPosition(assignment, 0, preset) : 0;
  const [from, to] = pos < centre ? [pos, centre] : [centre, pos];
  return (
    <View style={styles.slider} onLayout={(e) => setWidth(e.nativeEvent.layout.width)}
          accessibilityRole="adjustable" accessibilityLabel={label} {...responder.panHandlers}>
      <View pointerEvents="none" style={styles.track} />
      {bipolar && <View pointerEvents="none" style={[styles.centre, { left: `${centre * 100}%` }]} />}
      <View pointerEvents="none" style={[styles.fill, { left: `${from * 100}%`, width: `${(to - from) * 100}%` },
                                          !finite && styles.fillSpecial]} />
      <View pointerEvents="none" style={[styles.thumb, { left: `${pos * 100}%` }]} />
    </View>
  );
}

interface ChoiceProps {
  readonly options: readonly ChoiceOption[];
  readonly value: Value;
  readonly onChange: (value: Value) => void;
}

export function Choice({ options, value, onChange }: ChoiceProps) {
  return (
    <View style={styles.choice} accessibilityRole="radiogroup">
      {options.map((o) => {
        const selected = o.value === value;
        return (
          <Pressable key={String(o.value)} onPress={() => onChange(o.value)}
                     accessibilityRole="radio" accessibilityState={{ selected }}
                     style={[styles.option, selected && styles.optionOn]}>
            <Text style={[styles.optionText, selected && styles.optionTextOn]}>{o.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

interface StepperProps {
  readonly value: number;
  readonly min: number;
  readonly max: number;
  readonly step: number;
  readonly onChange: (value: number) => void;
}

export function Stepper({ value, min, max, step, onChange }: StepperProps) {
  return (
    <View style={styles.stepper}>
      <Pressable style={styles.stepButton} disabled={value <= min} onPress={() => onChange(value - step)}
                 accessibilityLabel="decrease">
        <Text style={styles.stepText}>−</Text>
      </Pressable>
      <Pressable style={styles.stepButton} disabled={value >= max} onPress={() => onChange(value + step)}
                 accessibilityLabel="increase">
        <Text style={styles.stepText}>+</Text>
      </Pressable>
    </View>
  );
}

interface ValueEntryProps {
  readonly text: string;              // the formatted value
  readonly editable: boolean;
  readonly special: readonly number[];
  readonly onSubmit: (value: number) => void;
}

// The value, formatted; tap to type a number in the parameter's unit
// ("inf" or "-inf" where the parameter has them).
export function ValueEntry({ text, editable, special, onSubmit }: ValueEntryProps) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  if (!editing)
    return (
      <Pressable disabled={!editable} onPress={() => { setDraft(''); setEditing(true); }}
                 accessibilityHint="type an exact value">
        <Text style={styles.value} numberOfLines={1}>{text}</Text>
      </Pressable>
    );
  const submit = () => {
    const t = draft.trim().toLowerCase().replace(',', '.').replace('−', '-');
    const v = t === 'inf' ? Infinity : t === '-inf' ? -Infinity : Number(t);
    if (t !== '' && !Number.isNaN(v) && (Number.isFinite(v) || special.includes(v))) onSubmit(v);
    setEditing(false);
  };
  return (
    <TextInput style={[styles.value, styles.entry]} autoFocus value={draft} onChangeText={setDraft}
               onSubmitEditing={submit} onBlur={submit} keyboardType="numbers-and-punctuation"
               placeholder={text} placeholderTextColor="#5c6672" />
  );
}

const styles = StyleSheet.create({
  slider: { height: 32, justifyContent: 'center' },
  track: { height: 4, borderRadius: 2, backgroundColor: '#2c3138' },
  centre: { position: 'absolute', width: 2, height: 12, marginLeft: -1, backgroundColor: '#59616d' },
  fill: { position: 'absolute', height: 4, borderRadius: 2, backgroundColor: ACCENT },
  fillSpecial: { backgroundColor: '#e05050' },
  thumb: {
    position: 'absolute', width: 18, height: 18, marginLeft: -9, borderRadius: 9,
    backgroundColor: '#e8e8e8', borderWidth: 2, borderColor: ACCENT,
  },
  choice: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  option: { paddingHorizontal: 10, paddingVertical: 7, borderRadius: 4, borderWidth: 1, borderColor: '#3a3f47' },
  optionOn: { backgroundColor: '#3a2a08', borderColor: ACCENT },
  optionText: { color: '#a8b0ba', fontSize: 13 },
  optionTextOn: { color: '#f0c070', fontWeight: '700' },
  stepper: { flexDirection: 'row', gap: 6 },
  stepButton: { width: 40, height: 32, borderRadius: 4, borderWidth: 1, borderColor: '#3a3f47', alignItems: 'center', justifyContent: 'center' },
  stepText: { color: '#e8e8e8', fontSize: 18 },
  value: { color: '#e8e8e8', fontSize: 13, minWidth: 92, textAlign: 'right', fontVariant: ['tabular-nums'] },
  entry: { borderBottomWidth: 1, borderColor: ACCENT, paddingVertical: 2 },
});
