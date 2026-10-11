# Noaidi companion

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The companion app (issue #198): a patch editor and a software prototype of
the Noaidi control surface, for Android tablets, Windows and macOS. It works
entirely offline: patches are local, portable TOML files in the format of
[docs/storage_format.md](../docs/storage_format.md).

The app works with semantic parameters such as `filter.cutoff` or
`lfo[1].depth`, in musical units. It does not hold a second model of the
synth: the parameter list comes from the firmware's own patch-file table.

## Layout

| Path | What |
|---|---|
| `src/core/` | pure TypeScript, no React or native imports: `parameters` (the manifest, normalizing values), `patch`, `patchFile` (TOML format 1), `patchStore`, `surface` (panel layouts, tapers, focus rules), `transport` (interface and `MockTransport`) |
| `src/display/` | companion-owned display metadata: label, section, unit, formatting, interaction, Editor control |
| `src/simulator/` | pure TypeScript: `panel` (simulated controls acting on the store and the surface), `knobGesture` (rotary or vertical knob drags), `displayBridge` (JSON messages to and from the LVGL display) |
| `src/layouts/` | panel layouts as data: grid placement, assignments, panel ranges and tapers, layers and their overviews; `layoutA` is the first whole-panel hypothesis |
| `src/app/` | React Native: `Panel` draws a layout (`Knob`, `Fader`, `Encoder`, `LayerButton`) around `LvglDisplay`, the real LVGL display in a WebView (iframe on web) |
| `src/generated/` | checked in: `parameters.json` (gen_manifest), `factoryPatches.ts` (app/storage), `displayHtml.ts` (the LVGL display page, `make -C display web`) |
| `test/` | vitest tests; `compat.test.ts` runs the firmware's own patch reader |
| `tools/gen_manifest/` | writes the parameter manifest |
| `tools/patch_tool/` | the firmware's patch reader and writer on the computer, for the compatibility tests |

## The screen

The instrument's screen is not drawn in React: it is the real display,
portable LVGL C in [../display](../display/README.md), compiled to
WebAssembly and packed into one self-contained page. React draws the
physical controls around it. The app talks to the display with JSON
messages (`src/simulator/displayBridge.ts` ↔ `display/ports/web/shell.js`),
sending each parameter as its index in the manifest, which is its
`noaidi_param_t` in `display/include/noaidi_param_ids.h`. Touches inside
the screen go to LVGL itself, and a tapped parameter comes back as a
`touched` message that focuses it through the surface core.

## Running

| Command | What it does |
|---|---|
| `npx expo start --web` | the app in a browser |
| `eas build -p android --profile preview` | an Android APK (Expo's build service) |

Expo Go is not used: the app is a development or release build.

## Building and testing

`npm install` once (`.npmrc` sets `legacy-peer-deps`: npm 10 otherwise
crashes on vitest's optional peers).

| Command | What it does |
|---|---|
| `make -C companion manifest` | regenerate the manifest, the display's `noaidi_param_ids.h` and `factoryPatches.ts` (needs a host C compiler) |
| `make -C companion check` | everything: manifest fresh and consistent, `tsc`, all tests including the compatibility tests (needs a host C compiler and `git submodule update --init app/lib/tomlc17`) |
| `npm test` | the TypeScript tests; the compatibility tests are skipped |

## Patch files

`src/core/patchFile.ts` reads and writes format 1 as the firmware's loader
does: keys apply in manifest order, a missing key takes its init value, a
value outside the range clamps. In addition the companion keeps what it
does not understand and writes it back: unknown keys and tables, unknown
keys in known tables and in `[[osc]]`/`[[lfo]]` elements, extra array
elements, and known keys with a value it cannot interpret (an unknown
name from newer firmware) until that parameter is edited. A file with a
newer `format` opens read-only with a warning. Comments and layout are not
kept: the writer writes its own clean form.

The compatibility contract is the musical patch, not the text, and
`test/compat.test.ts` checks it against the firmware's reader: the factory
patches and 300 random patches load to the same raw values both ways.

Values are kept in musical units. A value of a key with listed values is
snapped to the nearest one (by the key's `nearest` measure); other values
keep 9 significant digits.

## Display metadata

`src/display/parameters.ts` gives every parameter a label, section, unit,
formatter, interaction (`continuous`, `choice`, `toggle`, `stepped`) and
Editor control. The interaction is a UX choice, not derived from the
engine: an envelope time has 232 distinct values but is continuous to a
player. `test/display.test.ts` fails if a generated parameter has no entry.
Panel placement, range and taper are not display metadata; they belong to
each panel layout (`src/core/surface.ts`).

## Parameter manifest

`src/generated/parameters.json` lists every parameter a patch file holds,
generated from `app/main/patch_units.c` by `tools/gen_manifest`, which
compiles the firmware sources unchanged. The manifest is checked in, so
building the app needs no C compiler.

Run `make -C companion manifest` after any change to the patch-file keys,
and commit the result.

Each parameter entry has:

| Field | Meaning |
|---|---|
| `id` | semantic ID: table, `[index]` for arrays of tables (0-based; the UI shows Osc 1, LFO 2), key |
| `file` | where format 1 stores it: TOML `table`, `index`, `key` |
| `kind` | `"number"` or `"name"` |
| `names` | a name key's names |
| `initValue` | the init patch's value: what a file that omits the key loads as. The init patch is a neutral fallback, not a representative sound |
| `integer` | a number key that takes whole numbers only |
| `nearest` | how a value converts to the nearest engine value: `"difference"` (linear units) or `"ratio"` (seconds, Hz, Q) |
| `range` | min and max of the finite values the engine can hold; a file value outside it is clamped |
| `special` | values outside the finite range: `"inf"` (self-oscillating resonance), `"-inf"` (volume off) |
| `valueCount` | how many distinct values the key can hold |
| `values` | all of them, ascending, for keys with at most 1024 |
| `dependsOn` | the parameter whose value changes this one's conversion: decay depends on its envelope's sustain, an LFO's depth on its destination |
| `byValue` | for a dependency on a name: `range`, `valueCount` and `values` per name; `range` is then their union |

Numbers are the actual musical values to 6 significant digits, more where
needed to load back to the same raw value. The array is in the order the
firmware's loader applies the keys.

The manifest holds only what the engine does. Labels, units and number
formatting belong to the companion's display metadata, and the ranges a
panel control covers are part of each panel layout.
