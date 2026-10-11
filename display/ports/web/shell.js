// shell.js — hosts the Noaidi display (WebAssembly) in a page
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Draws the display's frames on a canvas, passes touches and clicks to
// LVGL, and speaks JSON messages with whoever hosts the page: a React
// Native WebView (window.ReactNativeWebView) or a parent window (iframe).
//
//   in:  { type: "value", param, value }   value: a number, "inf" or "-inf"
//        { type: "name",  param, name }
//        { type: "focus", param }          param -1: the layer overview
//        { type: "layer", label, assign: [p0, p1, p2, p3] }
//        { type: "overview", tiles: [p0, p1, p2, p3], graphic }
//                  graphic: 0 none, 1 filter, 2 amp envelope, 3 mod envelope
//        { type: "refresh", ms }           LVGL's redraw period (diagnostic)
//   out: { type: "ready", width, height }
//        { type: "touched", param }         the player tapped a parameter
//        { type: "fps", fps }               frames drawn per second, every 2 s
//
// param is a parameter's index in the manifest (noaidi_param_ids.h).
// window.noaidiDisplay is the WebAssembly module, for tests and the
// browser console.

(function () {
  const W = NOAIDI_WIDTH, H = NOAIDI_HEIGHT;   // replaced by make_html.py
  const canvas = document.getElementById('display');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d');

  // fill the page, keeping the display's aspect
  function fit() {
    const scale = Math.min(window.innerWidth / W, window.innerHeight / H);
    canvas.style.width = `${Math.floor(W * scale)}px`;
    canvas.style.height = `${Math.floor(H * scale)}px`;
  }
  window.addEventListener('resize', fit);
  fit();

  function send(msg) {
    const text = JSON.stringify(msg);
    if (window.ReactNativeWebView) window.ReactNativeWebView.postMessage(text);
    else if (window.parent !== window) window.parent.postMessage(text, '*');
  }

  createNoaidiDisplay().then((M) => {
    if (!M._web_init(W, H)) throw new Error('display: out of memory');
    window.noaidiDisplay = M;   // for tests and the browser console
    const rgba = M._web_rgba();
    const image = new ImageData(new Uint8ClampedArray(M.HEAPU8.buffer, rgba, W * H * 4), W, H);
    M.onDisplayEvent = (event, param) => {
      if (event === 0) send({ type: 'touched', param });
    };

    function handle(msg) {
      switch (msg.type) {
        case 'value': {
          const v = msg.value === 'inf' ? Infinity : msg.value === '-inf' ? -Infinity : msg.value;
          M._noaidi_display_set_value(msg.param, v);
          break;
        }
        case 'name':
          M.ccall('noaidi_display_set_name', null, ['number', 'string'], [msg.param, msg.name]);
          break;
        case 'focus':
          M._noaidi_display_focus(msg.param);
          break;
        case 'overview': {
          const t = msg.tiles;
          M._web_set_overview(t[0] ?? -1, t[1] ?? -1, t[2] ?? -1, t[3] ?? -1, msg.graphic ?? 0);
          break;
        }
        case 'refresh':
          M._web_set_refresh_period(msg.ms);
          break;
        case 'layer': {
          const a = msg.assign;
          M.ccall('web_set_layer', null, ['string', 'number', 'number', 'number', 'number'],
                  [msg.label, a[0] ?? -1, a[1] ?? -1, a[2] ?? -1, a[3] ?? -1]);
          break;
        }
      }
    }
    function onMessage(e) {
      try { handle(typeof e.data === 'string' ? JSON.parse(e.data) : e.data); } catch (_) { /* not ours */ }
    }
    window.addEventListener('message', onMessage);
    document.addEventListener('message', onMessage);   // Android WebView

    function point(e) {
      const r = canvas.getBoundingClientRect();
      return [Math.round((e.clientX - r.left) * W / r.width), Math.round((e.clientY - r.top) * H / r.height)];
    }
    canvas.addEventListener('pointerdown', (e) => {
      canvas.setPointerCapture(e.pointerId);
      M._web_pointer(...point(e), 1);
    });
    canvas.addEventListener('pointermove', (e) => M._web_pointer(...point(e), e.buttons ? 1 : 0));
    canvas.addEventListener('pointerup', (e) => M._web_pointer(...point(e), 0));
    canvas.addEventListener('pointercancel', (e) => M._web_pointer(...point(e), 0));

    let frames = 0, since = performance.now();
    function frame(now) {
      if (M._web_frame()) {
        ctx.putImageData(image, 0, 0);
        frames++;
      }
      if (now - since >= 2000) {
        send({ type: 'fps', fps: Math.round(frames * 1000 / (now - since)) });
        frames = 0;
        since = now;
      }
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
    send({ type: 'ready', width: W, height: H });
  });
})();
