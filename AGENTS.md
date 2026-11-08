# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents pay attention to what is going on at GitHub as they work: new comments and notifications on the issues and pull requests they are working on. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. GitHub has an API for issue ticket relationships (relates-to, blocked-by, parent-child) and agents *must* actively use it. Agents must also actively use labels when creating GitHub issues. When an agent pull request is approved, the agent must remove the branch it created for it.

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

- For audio shared with humans for review, agents *must* encode as MP3 at 320 kbps (using libmp3lame; `tools/lab/encode_capture.sh`). Lossless audio (WAV, FLAC) is reserved for production and analysis, never for human feedback. Review audio is sent over chat (the Discord thread where the work is discussed) as the MP3 attachment; never GitHub release assets, never a served folder.

- All source files shall carry the following copyright notice:

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```

# Delegated work

Subagents run on a cheaper model than the lead agent. That model has already failed on this codebase's RTL, so work is split by what it can be trusted with.

Suitable for a subagent:
- Web and datasheet research.
- Log and build-output digging.
- Running make/test targets and reporting the numbers.
- C firmware tasks with a test that decides done.
- Doc edits whose content is already specified.
- Reading document screenshots, datasheet figures and board photos. Where a PDF exists, `pdftotext` first; the subagent reads only what the text layer lacks. Numbers to be acted on (pins, registers, line references) get checked against the source.

Not suitable:
- Writing or debugging SystemVerilog.
- Anything touching fixed-point arithmetic or timing.
- Architecture decisions.
- PR review verdicts.

A subagent's output is delivered to the lead agent, never to a commit or a PR. The lead agent verifies before acting on it.

A subagent that finds itself editing RTL stops and reports instead.

# Finding your feet

- **The words:** `docs/glossary.md` defines every term the project uses in its own sense; a term that changes meaning changes there in the same PR.
- **The instrument:** `README.md` (what it is, wiring, build, console, preset storage); `docs/design.md` is the single architecture reference and links the rest — `memory_map.md` (control plane, sink words), `csp2_isa.md` / `csp2_architecture.md` (the CSP), `firmware_architecture.md`, `midi_schema.md` / `param_conventions.md` / `control_map.md` (the player's surface), `storage_format.md` (preset files).
- **The tools:** `tools/README.md` says what lives where by what it needs; `tools/lab/README.md` is the guide to driving the board. The build finds ESP-IDF and the CAD suite itself — never source `export.sh`; `tools/esp_idf.sh idf.py …` runs any idf.py command.
- **Two machines:** the cloud box (thj.no, this repo, builds, no board) and the lab box (`ssh -p 23000 thor@home.thj.no`, the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture). Both checkouts rest on `main`.
- **Division of labour:** the cloud box is where the agent lives (always on, static public IP, fast link, the host services, this repo) and where everything that is not a bitstream runs: the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks, the chat. The lab box builds every bitstream (`make pack.fs`: yosys, nextpnr, gowin_pack) and holds the board: its i3-8100B is about 1.5× the cloud box's Neoverse-N1 per core (one placement 6 min against 9, measured Nov 2026) and has four cores to its two, so a seed sweep (`tools/lab/placement_sweep.sh`, four seeds at once, one nextpnr being one thread and about 200 MB) and a board test's bitstream are both made there, never built on the cloud box and shipped over. The cloud box places only when the lab box is down. Seeds remain a diagnostic of the tool, never part of the build.
