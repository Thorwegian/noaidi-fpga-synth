// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The whole simulator path to the real display, with the checked-in page
// (src/generated/displayHtml.ts) run as shipped: patch store → display
// bridge → JSON message → shell.js → WebAssembly → LVGL label; and a touch
// on the LVGL screen back to a focus in the surface core and onto the
// screen again. The page runs in a Node VM with just enough of a browser
// (a window, a canvas, animation frames, a clock the test controls).

import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';

import { readPatchFile } from '../src/core/patchFile';
import { createPatchStore } from '../src/core/patchStore';
import { DISPLAY_HEIGHT, DISPLAY_HTML, DISPLAY_WIDTH } from '../src/generated/displayHtml';
import { FACTORY_FILES } from '../src/generated/factoryPatches';
import { filterSpike } from '../src/layouts/filterSpike';
import { connectDisplay, paramIndex, type FromDisplay } from '../src/simulator/displayBridge';
import { createPanel } from '../src/simulator/panel';

function scripts(html: string): string[] {
  return [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]!);
}

// A page with the display running in it.
async function openPage() {
  let time = 0;
  let frame: ((t: number) => void) | null = null;
  const fromPage: FromDisplay[] = [];
  const listeners: Record<string, ((e: any) => void)[]> = {};
  const on = (type: string, fn: (e: any) => void) => (listeners[type] ??= []).push(fn);
  const canvas = {
    width: 0, height: 0, style: {} as Record<string, string>,
    getContext: () => ({ putImageData: () => {} }),
    getBoundingClientRect: () => ({ left: 0, top: 0, width: DISPLAY_WIDTH, height: DISPLAY_HEIGHT }),
    setPointerCapture: () => {},
    addEventListener: (type: string, fn: (e: any) => void) => on(`canvas:${type}`, fn),
  };
  const window: any = {
    innerWidth: DISPLAY_WIDTH, innerHeight: DISPLAY_HEIGHT,
    addEventListener: on,
    ReactNativeWebView: { postMessage: (text: string) => fromPage.push(JSON.parse(text)) },
  };
  window.parent = window;
  const context: any = {
    window, document: { getElementById: () => canvas, addEventListener: on },
    performance: { now: () => time },
    requestAnimationFrame: (fn: (t: number) => void) => { frame = fn; },
    ImageData: class { constructor(public data: unknown) {} },
    WebAssembly, atob, console, setTimeout, clearTimeout, Uint8ClampedArray, TextDecoder,
  };
  context.self = context;
  for (const js of scripts(DISPLAY_HTML)) runInNewContext(js, context);

  const run = async (ms: number) => {
    for (let t = 0; t < ms; t += 10) {
      time += 10;
      frame?.(time);
      await Promise.resolve();
    }
  };
  for (let i = 0; i < 100 && !window.noaidiDisplay; i++) await new Promise((r) => setTimeout(r, 10));
  await run(50);
  const M = window.noaidiDisplay;
  return {
    fromPage,
    run,
    post: (message: unknown) =>
      listeners.message?.forEach((fn) => fn({ data: JSON.stringify(message) })),
    pointer: (type: string, x: number, y: number) =>
      listeners[`canvas:${type}`]?.forEach((fn) => fn({ clientX: x, clientY: y, buttons: type === 'pointerup' ? 0 : 1, pointerId: 1 })),
    shownValue: (id: string): string | null =>
      M.ccall('noaidi_display_shown_value', 'string', ['number'], [paramIndex(id)]),
    shownFocus: (): number => M._noaidi_display_shown_focus(),
    encoderLabel: (i: number): string => M.ccall('noaidi_display_shown_encoder_label', 'string', ['number'], [i]),
  };
}

describe('the real display through the simulator bridge', () => {
  it('shows the sound, the layer and the focus, and reports touches', async () => {
    const page = await openPage();
    expect(page.fromPage[0]).toEqual({ type: 'ready', width: DISPLAY_WIDTH, height: DISPLAY_HEIGHT });

    const store = createPatchStore(readPatchFile(FACTORY_FILES['Patches/Factory/Pads/Supersaw.toml']!).patch);
    let now = 0;
    const panel = createPanel(filterSpike, store, () => now);
    const bridge = connectDisplay(store, panel.surface, page.post, () => now);
    bridge.receive(page.fromPage[0]!);   // ready: the full state goes over

    expect(page.shownValue('filter.cutoff')).toBe('370 Hz');
    expect(page.shownValue('filter.resonance')).toBe('Q 1.00');
    expect(page.encoderLabel(0)).toBe('Type');
    expect(page.shownValue('filter.type')).toBe('LP');
    expect(page.shownValue('filter.slope')).toBe('24 dB');

    // a JS-side value change reaches the C display
    store.set('filter.cutoff', 2400);
    expect(page.shownValue('filter.cutoff')).toBe('2.40 kHz');

    // a moved virtual knob sets the value and focuses it on the display
    panel.move('resonance', 1);
    expect(page.shownValue('filter.resonance')).toBe('Q 32.00');
    expect(page.shownFocus()).toBe(paramIndex('filter.resonance'));

    // inactivity returns the display to the overview
    now += filterSpike.screen.focusTimeoutMs;
    panel.tick();
    expect(page.shownFocus()).toBe(-1);

    // a tap on the LVGL screen comes back and focuses that parameter
    page.pointer('pointerdown', 120, 90);
    await page.run(60);
    page.pointer('pointerup', 120, 90);
    await page.run(60);
    const touched = page.fromPage.find((m) => m.type === 'touched');
    expect(touched).toEqual({ type: 'touched', param: paramIndex('filter.cutoff') });
    bridge.receive(touched!);
    expect(panel.surface.getState().focus).toEqual({ control: 'screen', param: 'filter.cutoff' });
    expect(page.shownFocus()).toBe(paramIndex('filter.cutoff'));
    bridge.dispose();
  });
});
