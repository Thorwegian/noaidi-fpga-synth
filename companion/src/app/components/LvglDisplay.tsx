// LvglDisplay.tsx — the instrument's screen: the real LVGL display,
// compiled to WebAssembly, in a WebView (Android, iOS)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The page is inlined (DISPLAY_HTML), so it loads with no server and no
// network. Touches inside the page go to LVGL itself. LvglDisplay.web.tsx
// is the same for the browser, with an iframe.

import { forwardRef, useImperativeHandle, useRef } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import { WebView } from 'react-native-webview';

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
  const web = useRef<WebView>(null);
  useImperativeHandle(ref, () => ({
    post: (message) => web.current?.postMessage(JSON.stringify(message)),
  }), []);
  return (
    <WebView
      ref={web}
      style={[{ backgroundColor: '#000' }, style]}
      source={{ html: DISPLAY_HTML }}
      originWhitelist={['*']}
      scrollEnabled={false}
      overScrollMode="never"
      setBuiltInZoomControls={false}
      onMessage={(e) => {
        try { onMessage(JSON.parse(e.nativeEvent.data)); } catch { /* not ours */ }
      }}
    />
  );
});
