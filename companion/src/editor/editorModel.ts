// editorModel.ts — what the Editor shows: every stored parameter, grouped
// by the synth's structure, each with a control over its whole engine range
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Built from the generated catalogue and the display metadata, so a new
// synth parameter appears here with no Editor change. Unlike a panel
// layout, the Editor does not choose ranges: a slider spans what the
// engine can hold (for an LFO's depth, what its destination can hold).
//
// Pure TypeScript: no React or native imports.

import type { Preset } from '../core/preset';
import { effectiveSpec, parameter, parameters, type ParameterId, type Value } from '../core/parameters';
import type { Assignment, Taper } from '../core/surface';
import { display } from '../display/parameters';

export interface EditorSection {
  readonly title: string;
  readonly params: readonly ParameterId[];
}

export interface ChoiceOption {
  readonly value: Value;
  readonly label: string;
}

export type EditorControlSpec =
  | { readonly kind: 'choice'; readonly options: readonly ChoiceOption[] }
  | { readonly kind: 'stepper'; readonly min: number; readonly max: number; readonly step: number }
  | {
      readonly kind: 'slider';
      readonly assignment: Assignment;   // the engine range, with a taper
      readonly bipolar: boolean;         // centred: the range spans zero
      readonly special: readonly number[];   // values beyond the range: ±Infinity
    };

// The sections in the order their first parameter has in the catalogue
// (Voice, Osc 1, Osc 2, Filter, Amp envelope, Mod envelope, LFO 1, LFO 2,
// Part), each with its parameters in catalogue order.
export function editorSections(): EditorSection[] {
  const sections = new Map<string, ParameterId[]>();
  for (const p of parameters) {
    const title = display(p.id).section;
    if (!sections.has(title)) sections.set(title, []);
    sections.get(title)!.push(p.id);
  }
  return [...sections].map(([title, params]) => ({ title, params }));
}

function sliderTaper(nearest: 'difference' | 'ratio', min: number): Taper {
  return nearest === 'ratio' && min > 0 ? 'exponential' : 'linear';
}

// The control for parameter id, given the preset (an LFO's depth range
// depends on its destination).
export function editorControl(id: ParameterId, preset: Preset): EditorControlSpec {
  const p = parameter(id);
  const d = display(id, preset);
  if (p.kind === 'name')
    return { kind: 'choice', options: p.names.map((n) => ({ value: n, label: d.choiceLabels?.[n] ?? n })) };
  const spec = effectiveSpec(p, (other) => preset.values[other]!);
  if (d.interaction === 'toggle' || (d.editor === 'segmented' && spec.values && spec.values.length <= 6))
    return { kind: 'choice', options: (spec.values ?? []).map((v) => ({ value: v, label: d.format(v) })) };
  if (d.interaction === 'stepped')
    return { kind: 'stepper', min: spec.range.min, max: spec.range.max, step: 1 };
  const { min, max } = spec.range;
  return {
    kind: 'slider',
    assignment: { param: id, range: { min, max }, taper: sliderTaper(p.nearest, min) },
    bipolar: min < 0 && max > 0,
    special: spec.special,
  };
}
