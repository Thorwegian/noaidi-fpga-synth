# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents continuously watch for activity on GitHub with `tools/agent/gh_watch.sh --interval 60` running in the background (`run_in_background=true`): it is silent while nothing is new and exits — waking the agent — the moment GitHub has a comment or notification, so waiting costs no model turns; never poll with a model-turn loop. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. GitHub has an API for issue ticket relationships (relates-to, blocked-by, parent-child) and agents *must* actively use it. Agents must also actively use labels when creating GitHub issues. When an agent pull request is approved, the agent must remove the branch it created for it.

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

- Variable names *must* be descriptive and use industry standard textbook terminology.

- Raw values are raw values. There is no such unit as "LSB".

- A stored or loaded sound is a *preset*. "Patch" means a change to code or a tool, never a sound (#300).

- Before cloning SystemVerilog arrays for parallel access, remember that B-SRAM banks are dual-ported and dual-clocked.

- B-SRAM blocks can be used as a large LUT with 10 inputs and 18 outputs to replace complex logic.

- For audio shared with humans for review, agents *must* encode as MP3 at 320 kbps (using libmp3lame). Lossless audio (WAV, FLAC) is reserved for production and analysis, never for human feedback. Review audio goes into the repo's `public_html/` on the cloud box (`tools/lab/publish_capture.sh`), which is served at `https://thj.no/synth-claude-uploads/` — link that URL from the issue; never GitHub release assets.

- All source files shall carry the following copyright notice:

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```
# Finding your feet

- **The instrument:** `README.md` (what it is, wiring, build, console, preset storage); `docs/design.md` is the single architecture reference and links the rest — `memory_map.md` (control plane, sink words), `csp2_isa.md` / `csp2_architecture.md` (the CSP), `firmware_architecture.md`, `midi_schema.md` / `param_conventions.md` / `control_map.md` (the player's surface), `storage_format.md` (preset files).
- **The tools:** `tools/README.md` says what lives where by what it needs; `tools/lab/README.md` is the guide to driving the board. The build finds ESP-IDF and the CAD suite itself — never source `export.sh`; `tools/esp_idf.sh idf.py …` runs any idf.py command.
- **Two machines:** the cloud box (thj.no, this repo, builds, no board) and the lab box (`ssh -p 23000 thor@home.thj.no`, the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture). Scratch goes under `~/.local/tmp/claude` on either; both checkouts rest on `main`.
