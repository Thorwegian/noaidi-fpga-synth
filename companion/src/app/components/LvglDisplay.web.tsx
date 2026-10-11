// LvglDisplay.web.tsx — the instrument's screen in the browser: the real
// LVGL display (WebAssembly) in an iframe; see LvglDisplay.tsx
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

import { createElement, forwardRef, useEffect, useImperativeHandle, useRef } from 'react';
import { View, type StyleProp, type ViewStyle } from 'react-native';

import { DISPLAY_HTML } from '../../generated/displayHtml';
import type { FromDisplay, ToDisplay } from '../../simulator/displayBridge';

export interface DisplayHandle {
  post(message: ToDisplay): void;
}

interface Props {
  readonly style?: StyleProp<ViewStyle>;
  readonly onMessage: (message: FromDisplay) => void;
}

export const LvglDisplay = forwardRef<DisplayHandle, Props>(function LvglDisplay({ style, onMessage }, ref) {
  const frame = useRef<HTMLIFrameElement | null>(null);
  const latest = useRef(onMessage);
  latest.current = onMessage;

  useImperativeHandle(ref, () => ({
    post: (message) => frame.current?.contentWindow?.postMessage(JSON.stringify(message), '*'),
  }), []);

  useEffect(() => {
    const listen = (e: MessageEvent) => {
      if (e.source !== frame.current?.contentWindow || typeof e.data !== 'string') return;
      try { latest.current(JSON.parse(e.data)); } catch { /* not ours */ }
    };
    window.addEventListener('message', listen);
    return () => window.removeEventListener('message', listen);
  }, []);

  return (
    <View style={[{ backgroundColor: '#000' }, style]}>
      {createElement('iframe', {
        ref: frame,
        srcDoc: DISPLAY_HTML,
        title: 'Noaidi display',
        style: { border: 0, width: '100%', height: '100%', display: 'block' },
      })}
    </View>
  );
});
