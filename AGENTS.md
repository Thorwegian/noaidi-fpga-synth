# Rules

- Git policies:
  - Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories.
  - Agents read GitHub through GraphQL queries in preference to REST calls.
  - On the issues and pull requests they are working on, agents watch for new comments and notifications and *always* liveblog their progress in the comments.
  - Issues form a tree, read as a Makefile: a sub-issue is a prerequisite of its parent, and the issue to work on has no open sub-issues.
  - Sub-issues of one parent are independent of each other.
  - A new sub-issue is ranked among its siblings by how critical it is, the most critical first.
  - `blocked_by` is only for a prerequisite that several issues share.
  - GitHub allows one parent and eight levels.
  - An issue has its labels and its parent at creation; a parent with no work of its own is labelled `meta`.
  - Issue relations live in GitHub's fields, never in prose.
  - A PR's relation to its issue is `Fixes #n` in the PR body.
  - When an agent pull request is approved, the agent must remove the branch it created for it.

- Time-consuming tasks (builds, synthesis, simulations, PNR, recordings, etc.) are performed with `run_in_background=true`.

- Every session's work, a one-line docs PR included, happens in its own worktree, *never* in a shared one. The checkouts rest on `main` and are only ever pulled.

- The cloud box runs everything that is not a bitstream (the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks) and *never* builds one. A bitstream's chain is synthesis (yosys) on the lab box, place and route (nextpnr) on the Mac, *always*, then `gowin_pack` and the board take on the lab box. An rtl PR runs the chain once, at the default seed, and posts the take and the utilisation lines that moved as a PR comment.

- Every job on the Mac is started with `nice -n 20`.

- Seeds are a diagnostic of the tool, never part of the build. The seed sweep is a monitor, not a gate (#434): it starts after the board take.

- Agents never source ESP-IDF's `export.sh`.

- Agents write elegant and highly structured code at a senior developer level.

- Agents use Mermaid.js for diagrams and Matplotlib for graphs.

- Agents use Numpy, Scipy and Essentia for audio analysis.

- Agents write canonical C++ with the STL, *never* janky C hacks (C-style buffer juggling, sentinel values). C++ where it protects (RAII, std::string/std::string_view, std::optional, strong types, no raw buffers); a libc or POSIX call where it is the precise tool for the job (strcasestr, fsync, rename): chip (newlib) and host (glibc) are both POSIX. C code that does not conform goes on the agent's task list: agents *will* port C modules to C++ at every chance (dependencies excepted).

- Code in C-like languages is formatted in the style of the Oracle Java API Documentation.

- Agents *always* write canonical SystemVerilog, never janky Verilog hacks, and *will* change Verilog constructs to canonical SystemVerilog at every chance (dependencies excepted).

- Agents *always* look for and fix dead code, code that lives in two places and could live in one, and inconsistent code patterns.

- When designing an IP core (such as the CSP), rely mostly on Berkley, Princeton and Stanford research.

- Apply principles of universal design in user interfaces (and user-adjacent interfaces such as MIDI).

- Agents *must* update comments and docs so they match the code before *every* commit.

- Files in the repository document *state*: what the code and the design are and why they are so. They never say what something was before, what it replaced, or when and by whom it changed. Change is recorded where it happens: in the chat, the issue, the pull request and the commit message, and Git keeps the log. The only file that lists changes is one that is a changelog by name.

- Variable names *must* be descriptive and use industry standard textbook terminology.

- B-SRAM blocks can be used as a large LUT with 10 inputs and 18 outputs to replace complex logic.

- Audio for human review *must* be MP3 at 320 kbps (libmp3lame; `tools/lab/encode_capture.sh`), sent as an attachment in the Discord thread where the work is discussed; never GitHub release assets, never a served folder. Lossless audio (WAV, FLAC) is for production and analysis only.

- All source files shall carry the following copyright notice:

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```

# Finding your feet

## The words

- `docs/glossary.md` defines every term the project uses in its own sense.

## The instrument

- `README.md`: what it is, wiring, build, console, preset storage.
- `docs/design.md`: the single architecture reference. It links the rest:
  - `memory_map.md`: control plane, sink words.
  - `csp2_isa.md`, `csp2_architecture.md`: the CSP.
  - `firmware_architecture.md`.
  - `midi_schema.md`, `param_conventions.md`, `control_map.md`: the player's surface.
  - `storage_format.md`: preset files.

## The tools

- `tools/README.md` says what lives where by what it needs.
- `tools/lab/README.md` is the guide to driving the board.
- The build finds ESP-IDF and the CAD suite itself. `tools/esp_idf.sh idf.py …` runs any idf.py command.
- `tools/lab/placement_sweep.sh` is the seed sweep. Its heading says how it runs and where its verdict goes.

## Three machines

- The cloud box (thj.no): this repo, where the agent lives, no board.
- The lab box (`ssh -p 23000 thor@home.thj.no`): the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture.
- The Mac (`ssh -p 23456 hermes@home.thj.no`): an M2 Pro with six performance cores, and the machine Thor works at.
  - The agent's account there has no administrator rights. Its home is `/Volumes/Media/Hermes`.
  - The pinned nextpnr, built by hand, is in `~/nextpnr-bench/install`. There is no checkout of this repo.
  - It places against the lab box's `chipdb-GW2A-18C.bin`, copied over the one its own build generates.
  - The build places on the machine it runs on, so a placement is carried to the Mac by hand: `yosys.json` and `constraints.cst` over, nextpnr with the Makefile's options, `pnr.json` back.
- Worktrees live under `~/wt` on the cloud box and the lab box: `git worktree add ~/wt/wt-<issue> -b <branch> main`. A worktree holds its own `rtl/obj_dir`, `yosys.json` and `pnr.log`.
