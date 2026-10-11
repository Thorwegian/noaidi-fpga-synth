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

## Parameter manifest

`src/generated/parameters.json` lists every parameter a patch file holds,
generated from `app/main/patch_units.c` by `tools/gen_manifest`, which
compiles the firmware sources unchanged. The manifest is checked in, so
building the app needs no C compiler.

| Command | What it does |
|---|---|
| `make -C companion manifest` | regenerate the manifest (needs a host C compiler) |
| `make -C companion check` | fail if the manifest is stale or inconsistent |

Run `make -C companion manifest` after any change to the patch-file keys,
and commit the result.

Each parameter entry has:

| Field | Meaning |
|---|---|
| `id` | semantic ID: table, `[index]` for arrays of tables (0-based; the UI shows Osc 1, LFO 2), key |
| `file` | where format 1 stores it: TOML `table`, `index`, `key` |
| `kind` | `"number"` or `"name"` |
| `names` | a name key's names |
| `default` | the init patch's value |
| `integer` | a number key that takes whole numbers only |
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
