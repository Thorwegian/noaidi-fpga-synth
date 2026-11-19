# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents pay attention to what is going on at GitHub as they work: new comments and notifications on the issues and pull requests they are working on. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. Issues form a tree, read as a Makefile: a sub-issue is a prerequisite of its parent, and the issue to work on has no open sub-issues. Sub-issues of one parent are independent of each other. `blocked_by` is only for a prerequisite that several issues share. GitHub allows one parent and eight levels. An issue has its labels and its parent at creation; a parent with no work of its own is labelled `meta`. Relations live in GitHub's fields, never in prose. A PR's relation to its issue is `Fixes #n` in the PR body. When an agent pull request is approved, the agent must remove the branch it created for it.

- Time-consuming tasks (builds, synthesis, simulations, PNR, recordings, etc.) are performed with `run_in_background=true`.

- Agents write elegant and highly structured code at a senior developer level.

- Agents use Mermaid.js for diagrams and Matplotlib for graphs.

- Agents use Numpy, Scipy and Essentia for audio analysis.

- Canonical C++ with STL is *always* preferred over janky C hacks. Use C++ where it protects (RAII, std::string/std::string_view, std::optional, strong types, no raw buffers) and a libc or POSIX call where it is the precise tool for the job (strcasestr, fsync, rename). The project runs on POSIX on both the chip (newlib) and the host (glibc); "janky C hacks" means C-style buffer juggling and sentinel values, not calling the C library. Agents *will* port C modules to C++ at every chance (dependencies excepted).

- Code in C-like languages is formatted in the style of the Oracle Java API Documentation.

- Canonical SystemVerilog is *always* preferred over janky Verilog hacks. Agents *will* change Verilog constructs to canonical SystemVerilog constructs at every chance (dependencies excepted).

- Always look for dead code, duplicates, similar code in two places that could live in one and inconsistent code patterns, and bring these to the attention of the user.

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
- A term that changes meaning changes there in the same PR.

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
- The build finds ESP-IDF and the CAD suite itself. Never source `export.sh`.
- `tools/esp_idf.sh idf.py …` runs any idf.py command.

## Three machines

- The cloud box (thj.no): this repo, builds, no board.
- The lab box (`ssh -p 23000 thor@home.thj.no`): the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture.
- The Mac (`ssh -p 23456 hermes@home.thj.no`): an M2 Pro with six performance cores, and the machine Thor works at.
  - The agent's account there has no administrator rights. Its home is `/Volumes/Media/Hermes`.
  - It holds the pinned nextpnr, built by hand, in `~/nextpnr-bench/install`, and no checkout of this repo.
- Both checkouts rest on `main` and are only ever pulled.
- Parallel sessions never share a working tree. Every session's work, a one-line docs PR included, happens in its own worktree: `git worktree add ~/wt/wt-<issue> -b <branch> main`, under `~/wt` on both boxes.
- A worktree holds its own `rtl/obj_dir`, `yosys.json` and `pnr.log`.
- The session that made a worktree removes it when its PR merges.

## Division of labour

- The cloud box is where the agent lives. Everything that is not a bitstream runs there: the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks, the chat.
- The lab box builds every bitstream (`make pack.fs`: yosys, nextpnr, gowin_pack) and holds the board.
  - A seed sweep and a board test's bitstream are made there, never built on the cloud box and shipped over.
  - The cloud box places only when the lab box is down.
- Place and route is the Mac's work.
  - The build places on the machine it runs on (#465), so a placement for the Mac is carried there by hand: `yosys.json` and `constraints.cst` over, nextpnr with the Makefile's options, `pnr.json` back to the lab box for `gowin_pack` and the take.
  - Every job on the Mac is started with `nice -n 20`. The job is given the low priority, never the SSH service.
  - The Mac's nextpnr places against the lab box's `chipdb-GW2A-18C.bin`, copied over the one its own build generates.
- A seed names a placement only on the machine that ran it. Seeds are a diagnostic of the tool, never part of the build.
- An rtl PR's chain runs on the lab box:
  1. Synthesis.
  2. One placement at the default seed.
  3. `pack.fs`.
  4. The board take.
  5. The PR comment with the take and the utilisation lines that moved.
- The sweep (`tools/lab/placement_sweep.sh`, four random seeds at once) is a monitor, not a gate (#434).
  - It starts after the take, in the background: `REPORT=1 nohup tools/lab/placement_sweep.sh … &`.
  - When it ends, the script posts its verdict as a commit status on the swept commit (context `sweep`). The agent relays it to the chat.
  - A `sweep WARNING` (a draw that failed to place or route, or a floor under 85 MHz) or a `sweep FAIL` (a draw under the clock) also opens an issue under #363, by the script (#443).
  - Nothing about a sweep goes on a PR as a comment.
  - Its placements run at the lowest CPU priority, so a take started during one is not slowed.
