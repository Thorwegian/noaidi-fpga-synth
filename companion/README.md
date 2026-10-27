# Noaidi companion

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The companion app (issue #198): a preset editor and a software prototype of
the Noaidi control surface, for Android tablets, Windows and macOS. It works
entirely offline: presets are local, portable TOML files in the format of
[docs/storage_format.md](../docs/storage_format.md).

The app works with semantic parameters such as `filter.cutoff` or
`lfo[1].depth`, in musical units. It does not hold a second model of the
synth: the parameter list comes from the firmware's own preset-file table.

## Layout

| Path | What |
|---|---|
| `src/core/` | pure TypeScript, no React or native imports: `parameters` (the manifest, normalizing values), `preset`, `presetFile` (TOML format 1), `presetStore`, `surface` (panel layouts, tapers, focus rules), `transport` (interface and `MockTransport`) |
| `src/display/` | companion-owned display metadata: label, section, unit, formatting, interaction, Editor control |
| `src/library/` | pure TypeScript: the factory and user library (`library`), preset-name rules (`presetName`), and the session: the current preset, where it came from, Save / Save As / Export (`session`) |
| `src/editor/` | pure TypeScript: the Editor's sections and controls, from the catalogue and display metadata (`editorModel`) |
| `src/companion.ts` | the parts wired together: one session whose store the views, the display bridge and the transport share |
| `src/simulator/` | pure TypeScript: `panel` (simulated controls acting on the store and the surface), `knobGesture` (rotary or vertical knob drags), `displayBridge` (JSON messages to and from the LVGL display) |
| `src/layouts/` | panel layouts as data: grid placement, assignments, panel ranges and tapers, layers and their overviews; `layoutA` is the first whole-panel hypothesis |
| `src/app/` | React Native: the Library, Editor and Panel tabs (`App`), `editor/` (full-range controls), `library/` (list, Save As), `platform/files` (user library, import, export), and `Panel`, which draws a layout (`Knob`, `Fader`, `Encoder`, `LayerButton`) around `LvglDisplay`, the real LVGL display in a WebView (iframe on web) |
| `src/generated/` | checked in: `parameters.json` (gen_manifest), `factoryPresets.ts` (app/storage), `displayHtml.ts` (the LVGL display page, `make -C display web`) |
| `test/` | vitest tests; `compat.test.ts` runs the firmware's own preset reader |
| `tools/gen_manifest/` | writes the parameter manifest |
| `tools/preset_tool/` | the firmware's preset reader and writer on the computer, for the compatibility tests |

## Library, Editor and Panel

The app has three views of one current preset: the **Library** (factory
presets from the firmware tree, by category, and the user's own), the
**Editor** (every stored parameter over its whole engine range, grouped as
the synth is: Voice, Osc 1, Osc 2, Filter, the two envelopes, the two LFOs,
Part) and the **Panel** (Layout A around the real display). Opening,
editing and saving all act on the one preset store.

Saving follows the synth's layout and never needs a network:
- user presets live in the app's own storage as
  `Presets/User/<Category>/<Name>.toml` (browser storage on the web);
- **Save** writes back to the user preset that is open; a factory
  preset, an imported file or the startup preset needs **Save As**, which
  makes a user preset: factory presets are never written;
- **Import** opens a `.toml` from anywhere the system's file picker offers;
  **Export** writes the preset as `<Name>.toml` into a folder the user
  picks (a download on the web);
- a file whose `format` is newer than the companion's opens read-only:
  no Save, Save As or Export.

Preset names follow the synth's rules (`src/library/presetName.ts`,
checked against the firmware's `preset_name_valid`), and the categories
are the firmware's own list (`s_categories` in `app/main/storage.c`).

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
| `make -C companion manifest` | regenerate the manifest, the display's `noaidi_param_ids.h` and `factoryPresets.ts` (needs a host C and C++ compiler) |
| `make -C companion check` | everything: manifest fresh and consistent, `tsc`, all tests including the compatibility tests (needs a host C and C++ compiler and `git submodule update --init app/lib/tomlc17`) |
| `npm test` | the TypeScript tests; the compatibility tests are skipped |

## Preset files

`src/core/presetFile.ts` reads and writes format 1 as the firmware's loader
does: keys apply in manifest order, a missing key takes its init value, a
value outside the range clamps. In addition the companion keeps what it
does not understand and writes it back: unknown keys and tables, unknown
keys in known tables and in `[[osc]]`/`[[lfo]]` elements, extra array
elements, and known keys with a value it cannot interpret (an unknown
name from newer firmware) until that parameter is edited. A file with a
newer `format` opens read-only with a warning. Comments and layout are not
kept: the writer writes its own clean form.

The compatibility contract is the musical preset, not the text, and
`test/compat.test.ts` checks it against the firmware's reader: the factory
presets and 300 random presets load to the same raw values both ways.

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

`src/generated/parameters.json` lists every parameter a preset file holds,
generated from `app/main/preset_units.c` by `tools/gen_manifest`, which
compiles the firmware sources unchanged. The manifest is checked in, so
building the app needs no C or C++ compiler.

Run `make -C companion manifest` after any change to the preset-file keys,
and commit the result.

Each parameter entry has:

| Field | Meaning |
|---|---|
| `id` | semantic ID: table, `[index]` for arrays of tables (0-based; the UI shows Osc 1, LFO 2), key |
| `file` | where format 1 stores it: TOML `table`, `index`, `key` |
| `kind` | `"number"` or `"name"` |
| `names` | a name key's names |
| `initValue` | the init preset's value: what a file that omits the key loads as. The init preset is a neutral fallback, not a representative sound |
| `integer` | a number key that takes whole numbers only |
| `nearest` | how a value converts to the nearest engine value: `"difference"` (linear units) or `"ratio"` (seconds, Hz, Q) |
| `range` | min and max of the finite values the engine can hold; a file value outside it is clamped |
| `special` | values outside the finite range: `"inf"` (self-oscillating resonance), `"-inf"` (volume off) |
| `valueCount` | how many distinct values the key can hold |
| `values` | all of them, ascending, for keys with at most 1024 |
| `dependsOn` | the parameter whose value changes this one's conversion, found by probing: today only an LFO's depth, on its destination |
| `byValue` | for a dependency on a name: `range`, `valueCount` and `values` per name; `range` is then their union |

Numbers are the actual musical values to 6 significant digits, more where
needed to load back to the same raw value. The array is in the order the
firmware's loader applies the keys.

The manifest holds only what the engine does. Labels, units and number
formatting belong to the companion's display metadata, and the ranges a
panel control covers are part of each panel layout.
