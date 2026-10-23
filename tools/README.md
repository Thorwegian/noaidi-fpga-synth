# The tools: what lives where

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

One rule decides the folder: what the thing needs.

- **`scripts/`** — build-time generators, invoked by `make`: the LUTs, the
  boot image, `tools.sh`. Nothing here is run by hand.
- **`tools/netlist/`** — gates and inspection of the *routed* design.
  `pin_audit.py` and `check_timing.py` run inside `make pack.fs` (`rtl/Makefile`);
  `synth_report.py` reads the place-and-route report; `pin_distance.py` and
  `placement_check.py` are run by hand on a routed nextpnr JSON.
- **`tools/esp_idf.sh`** — the firmware's toolchain, found without a wrapper:
  `tools/esp_idf.sh idf.py build` runs any `idf.py` command with ESP-IDF
  activated, `--where` says which ESP-IDF it found. The Makefile's `fw*`
  targets go through it; nobody sources `export.sh` by hand.
- **`tools/csp/`** — the CSP's assembler, reference model and host tests.
  **`tools/storage/`** — the storage partition image, for the Makefile.
  **`tools/docs/`** — `mermaid_check.mjs`, which parses every Mermaid graph in
  the Markdown. **`tools/osc_panel/`** — the Open Stage Control surface.
- **`tools/agent/`** — the agent's own workflow tools. `gh_watch.sh` waits,
  silently, for something new on GitHub: a background loop that polls the
  repository-wide comments, the issues, the inbox and `main`'s head every minute, prints
  nothing while nothing is new, and exits the moment there is — the exit is
  what wakes the agent, so waiting on a human costs no model turns (a merge
  reached the agent in 56 s at that interval). Seed the first run with
  `--since <last covered time>`.
- **`tools/lab/`** — everything that needs the board or the lab computer:
  driving the console and MIDI, the acceptances, the recordings and their
  Essentia analysis (the recordings only exist because of the lab), the
  console logger and the capture publisher. **`tools/lab/ble/`** holds the
  checks written during BLE development — dormant since, kept for when they
  are useful again; every one drives the synth over its single BLE
  connection. `tools/lab/README.md` is the guide to driving the board.
