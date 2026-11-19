# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents pay attention to what is going on at GitHub as they work: new comments and notifications on the issues and pull requests they are working on. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. Issues form a tree, read as a Makefile: a sub-issue is a prerequisite of its parent, and the issue to work on has no open sub-issues. Sub-issues of one parent are independent of each other. `blocked_by` is only for a prerequisite that several issues share. GitHub allows one parent and eight levels. An issue has its labels and its parent at creation; a parent with no work of its own is labelled `meta`. Issue relations live in GitHub's fields, never in prose. A PR's relation to its issue is `Fixes #n` in the PR body. When an agent pull request is approved, the agent must remove the branch it created for it.

- Time-consuming tasks (builds, synthesis, simulations, PNR, recordings, etc.) are performed with `run_in_background=true`.

- Parallel sessions never share a working tree. Every session's work, a one-line docs PR included, happens in its own worktree. The checkouts rest on `main` and are only ever pulled.

- A bitstream is never built on the cloud box. The lab box synthesises (yosys) and packs (`gowin_pack`). Place and route (nextpnr) runs on the Mac, always.

- Every job on the Mac is started with `nice -n 20`. The job is given the low priority, never the SSH service.

- Everything that is not a bitstream runs on the cloud box: the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks.

- An rtl PR's chain is synthesis, one placement at the default seed, `pack.fs`, the board take, and the PR comment with the take and the utilisation lines that moved.

- Seeds are a diagnostic of the tool, never part of the build. The seed sweep is a monitor, not a gate (#434): it starts after the board take, in the background.

- Agents never source ESP-IDF's `export.sh`.

- Agents write elegant and highly structured code at a senior developer level.

- Agents use Mermaid.js for diagrams and Matplotlib for graphs.

- Agents use Numpy, Scipy and Essentia for audio analysis.

- Canonical C++ with STL is *always* preferred over janky C hacks. Use C++ where it protects (RAII, std::string/std::string_view, std::optional, strong types, no raw buffers) and a libc or POSIX call where it is the precise tool for the job (strcasestr, fsync, rename). The project runs on POSIX on both the chip (newlib) and the host (glibc); "janky C hacks" means C-style buffer juggling and sentinel values, not calling the C library. Agents *will* port C modules to C++ at every chance (dependencies excepted).

- Code in C-like languages is formatted in the style of the Oracle Java API Documentation.

- Canonical SystemVerilog is *always* preferred over janky Verilog hacks. Agents *will* change Verilog constructs to canonical SystemVerilog constructs at every chance (dependencies excepted).

- Always look for and fix dead code, duplicates, similar code in two places that could live in one and inconsistent code patterns.

- When designing an IP core (such as the CSP), rely mostly on Berkley, Princeton and Stanford research.

- Apply principles of universal design in user interfaces (and user-adjacent interfaces such as MIDI).

- Agents *must* update comments and docs so they match the code before *every* commit.

- Files in the repository document *state*: what the code and the design are and why they are so. They never say what something was before, what it replaced, or when and by whom it changed. Change is recorded where it happens: in the chat, the issue, the pull request and the commit message, and Git keeps the log. The only file that lists changes is one that is a changelog by name.

- Variable names *must* be descriptive and use industry standard textbook terminology.

- Raw values are raw values. There is no such unit as "LSB".

- A stored or loaded sound is a *preset*. "Patch" means a change to code or a tool, never a sound (#300).

- Before cloning SystemVerilog arrays for parallel access, remember that B-SRAM banks are dual-ported and dual-clocked.

- B-SRAM blocks can be used as a large LUT with 10 inputs and 18 outputs to replace complex logic.

- For audio shared with humans for review, agents *must* encode as MP3 at 320 kbps (using libmp3lame; `tools/lab/encode_capture.sh`). Lossless audio (WAV, FLAC) is reserved for production and analysis, never for human feedback. Review audio is sent over chat (the Discord thread where the work is discussed) as the MP3 attachment; never GitHub release assets, never a served folder.

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
  - The build places on the machine it runs on, so a placement is carried to the Mac by hand: `yosys.json` and `constraints.cst` over, nextpnr with the Makefile's options, `pnr.json` back to the lab box for `gowin_pack` and the take.
- Worktrees live under `~/wt` on the cloud box and the lab box: `git worktree add ~/wt/wt-<issue> -b <branch> main`. A worktree holds its own `rtl/obj_dir`, `yosys.json` and `pnr.log`.
- A seed names a placement only on the machine that ran it.
