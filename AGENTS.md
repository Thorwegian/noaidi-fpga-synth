# Rules

- Git policies:
  - Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories.
  - Agents read GitHub through GraphQL queries in preference to REST calls.
  - On the issues and pull requests they are working on, agents watch for new comments and notifications and *always* liveblog their progress in the comments.
  - Issues form a tree, read as a Makefile: a sub-issue is a prerequisite of its parent, and the issue to work on has no open sub-issues.
  - Sub-issues of one parent are independent of each other.
  - `blocked_by` is for a prerequisite that several issues share, or for one that belongs under another `meta`: the sub-issue edge would file it in the wrong place.
  - GitHub allows one parent and eight levels.
  - An issue has its labels and its parent at creation; a parent with no work of its own is labelled `meta`.
  - An issue's title says in plain words what is wrong and who notices.
  - An undecided item belongs to the issue that settles it: a measurement in the issue that measures, an implementation detail in a sub-issue, a deferred control in its own issue blocked by the parent. A parent's Undecided list ends empty.
  - An issue's body is trimmed of what belongs to its sub-issues: the child's problem is the child's.
  - An undecided item is the agent's to settle or Thor's to answer. A technical item is the agent's: the investigation settles it, and the list holds only what his answer alone can settle.
  - Issue relations live in GitHub's fields, never in prose.
  - A PR's relation to its issue is `Fixes #n` in the PR body, and *n* is the issue whose work the PR lands: never a `meta`, whose closing is Thor's to make.
  - When an agent pull request is approved, the agent must remove the branch it created for it.

- Triaging:
  - When checking GitHub, propose issues to quick fix, rerank, reparent, consolidate, update or close.
  - An issue ranks by how much, and how often, it annoys a keyboard player. A bug that can cause systemic faults ranks above a mild annoyance; what the typical keyboard player's audio gear already does ranks low.
  - A new sub-issue is ranked among its siblings by how critical it is, the most critical first.

- Time-consuming tasks (builds, synthesis, simulations, PNR, recordings, etc.) are performed with `run_in_background=true`.

- Every session's work, a one-line docs PR included, happens in its own worktree, *never* in a shared one. The checkouts rest on `main` and are only ever pulled.

- The cloud box runs everything that is not a bitstream (the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks) and *never* builds one. A bitstream's chain is synthesis (yosys) on the lab box, place and route (nextpnr) on the Mac, *always*, then `gowin_pack` and the board take on the lab box. An rtl PR runs the chain once, at the default seed, and posts the take and the utilisation lines that moved as a PR comment.

- Every job on the Mac is started with `nice -n 20`.

- Seeds are a diagnostic of the tool, never part of the build. The seed sweep is a monitor, not a gate (#434): it starts after the board take.

- Agents never source ESP-IDF's `export.sh`.

- Agents write elegant and highly structured code at a senior developer level.

- Agents use Mermaid.js for diagrams and Matplotlib for graphs.

- Agents use Numpy, Scipy and Essentia for audio analysis. Essentia is the agent's ear, not the human's: an agent hears nothing, so a description of the recording is all it has to judge a sound by. Reach for the perceptual descriptions first (log attack time, sensory dissonance, inharmonicity, tristimulus, EBU R128 loudness), which say what the sound is like, and the signal's own (pitch per frame, centroid, envelope) after them, which say only that the output is as expected.

- Suspect the measurement before the design: a silent take or a wrong value is the capture path, the flashed build or the MIDI parser until each is ruled out.

- Every take carries a control that must not move and a known value that must be right.

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

## The craft

- How these instruments are played and programmed, in other people's words: Gordon Reid's *Synth Secrets* (Sound On Sound, 63 parts, <https://www.soundonsound.com/series/synth-secrets-sound-sound>); the Nord Lead 2 manual's "About Subtractive Synthesis" (<https://www.nordkeyboards.com/wt/documents/217/Nord%20Lead%202%20English%20User%20Manual%20v1.0.pdf>); the ARP 2600 owner's manual (<https://cdn.korg.com/us/support/download/files/cb766ad31ea603642fe01f107abe7d86.pdf>); the JP-8000 Basic Synthesis notes `param_conventions.md` cites (<https://cdn.roland.com/assets/media/pdf/JP8000_Basic_Synthesis.pdf>).
- Guidance, not rules. They describe other instruments, and no two models overlap: read them for what a sound needs and why, then translate to our controls ([param_conventions.md](docs/param_conventions.md) says what ours do). Do not stop at a field a guide names that we do not have.

## You are deaf

- Judge a sound by the take, never by a plot: send Thor the audio and let him hear it.
- A metric says what changed; only he says whether it sounds right.
- Any conclusion about how it sounds ends with a take in the thread, not a picture.

# Paradigms

A synthesiser is a 3D renderer for music.

- A raytracer that traces no rays has failed, however green its tests: a sample is to a sound what a pixel is to a picture.

- A voice is a little monophonic synthesiser of its own that just happens to be controlled by the same channel as the others: they meet at the channel and nowhere else.

- A channel is a little synthesiser of its own that just happens to draw on the shared voice pool, just happens to share the MIDI cable with the synths beside it, and just happens to be plugged into the same mixing desk: they meet at those three and nowhere else, and nothing beyond the channel sets what it sounds like.
