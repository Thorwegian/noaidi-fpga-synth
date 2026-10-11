// Panel.tsx — draws a layout: its controls, groups and the display, placed
// on the layout's grid
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Everything about where things go comes from the Layout; everything about
// what a control does comes from the Panel (src/simulator/panel.ts). This
// component only draws and forwards touches.

import { forwardRef, useState, type ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { PatchStore } from '../../core/patchStore';
import type { Cell, Layout } from '../../core/surface';
import { display } from '../../display/parameters';
import type { FromDisplay } from '../../simulator/displayBridge';
import type { Panel as PanelModel } from '../../simulator/panel';
import { Encoder } from './Encoder';
import { Fader } from './Fader';
import { Knob } from './Knob';
import { LayerButton } from './LayerButton';
import { LvglDisplay, type DisplayHandle } from './LvglDisplay';

interface Props {
  readonly layout: Layout;
  readonly panel: PanelModel;
  readonly store: PatchStore;
  readonly showValues: boolean;
  readonly onDisplayMessage: (message: FromDisplay) => void;
}

const GAP = 6;

export const Panel = forwardRef<DisplayHandle, Props>(function Panel(
  { layout, panel, store, showValues, onDisplayMessage }, screen) {
  const [size, setSize] = useState({ w: 0, h: 0 });
  const cw = size.w / layout.grid.columns, ch = size.h / layout.grid.rows;
  const unit = Math.min(cw, ch);

  const rect = (at: Cell, span: Cell = [1, 1]) => ({
    position: 'absolute' as const,
    left: at[0] * cw + GAP, top: at[1] * ch + GAP,
    width: span[0] * cw - 2 * GAP, height: span[1] * ch - 2 * GAP,
  });

  const state = panel.surface.getState();
  const activeButton = layout.layers.find((l) => l.id === state.layerId)?.button;

  const controls: ReactNode[] = layout.controls.map((c) => {
    const a = layout.fixed[c.id];
    const label = c.label ?? (a ? display(a.param).shortLabel : '');
    const valueText = showValues && a ? display(a.param, store.getPatch()).format(store.get(a.param)) : undefined;
    let body: ReactNode = null;
    switch (c.kind) {
      case 'knob':
        body = <Knob label={label} size={unit * 0.62} position={panel.position(c.id)} valueText={valueText}
                     onTouch={() => panel.touch(c.id)} onMove={(p) => panel.move(c.id, p)} />;
        break;
      case 'fader':
        body = <Fader label={label} position={panel.position(c.id)} valueText={valueText}
                      onTouch={() => panel.touch(c.id)} onMove={(p) => panel.move(c.id, p)} />;
        break;
      case 'encoder':
        body = <Encoder size={unit * 0.6} onTouch={() => panel.touch(c.id)} onTurn={(s) => panel.turn(c.id, s)} />;
        break;
      case 'button':
        body = <LayerButton label={c.label ?? c.id} active={activeButton === c.id} onPress={() => panel.press(c.id)} />;
        break;
    }
    return <View key={c.id} style={[rect(c.at, c.span), styles.slot]}>{body}</View>;
  });

  return (
    <View style={styles.panel} onLayout={(e) => setSize({ w: e.nativeEvent.layout.width, h: e.nativeEvent.layout.height })}>
      {size.w > 0 && (
        <>
          {(layout.groups ?? []).map((g) => (
            <View key={g.label} pointerEvents="none" style={[rect(g.at, g.span), styles.group]}>
              <Text style={styles.groupLabel}>{g.label}</Text>
            </View>
          ))}
          <View style={[rect(layout.display.at, layout.display.span), styles.bezel]}>
            <LvglDisplay ref={screen} style={styles.screen} onMessage={onDisplayMessage} />
          </View>
          {controls}
        </>
      )}
    </View>
  );
});

const styles = StyleSheet.create({
  panel: { flex: 1 },
  slot: { alignItems: 'center', justifyContent: 'center', paddingTop: 10 },
  group: { borderWidth: 1, borderColor: '#2c3138', borderRadius: 8 },
  groupLabel: {
    position: 'absolute', top: -8, left: 10, paddingHorizontal: 6, backgroundColor: '#14171c',
    color: '#6c7682', fontSize: 10, fontWeight: '700', letterSpacing: 1.5,
  },
  bezel: { backgroundColor: '#050607', borderRadius: 10, padding: 8, borderWidth: 2, borderColor: '#262a31' },
  screen: { flex: 1 },
});
