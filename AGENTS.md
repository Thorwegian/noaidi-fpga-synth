# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents pay attention to what is going on at GitHub as they work: new comments and notifications on the issues and pull requests they are working on. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. Issue relations live in GitHub's fields, never in prose, and the relation is the parent: an issue belongs to the family whose goal it serves, and two issues that belong together share a parent rather than referring to each other. Before opening an issue the agent looks for its family among the open parents (`gh issue list --state open --label meta`, then a search on the topic, `gh issue list --state open --search "<words>"`), and an agent-opened issue has, at creation, its labels and its parent (`gh api -X POST repos/<r>/issues/<parent>/sub_issues -F sub_issue_id=<id>`, the id from `gh api repos/<r>/issues/<n> --jq .id`). Only when no open issue is its parent does the agent open the parent first (labelled `meta`, the family's home: a body stating the goal and the rule, never a list of its children). The one other relation is the dependency, for an issue that cannot be worked before another lands (`gh api -X POST repos/<r>/issues/<n>/dependencies/blocked_by -F issue_id=<id>`); it states the order of work, not kinship. The field is the only place a relation lives: `gh issue view` prints `parent:`, `sub-issues:`, `blocked-by:` and `blocking:` in every issue's header, so "see #n", "sibling of #n", "parent: #n" or "blocked by #n" written in a body or a comment is noise when it agrees with the field and a lie once the issue is re-parented. The body may say why the issue belongs to its family when the titles do not make it plain; that is a sentence about the design, not a link. A PR's relation to its issue is `Fixes #n` in the PR body. When an agent pull request is approved, the agent must remove the branch it created for it.

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

# Division of labour

The top agent is Claude Fable, with DeepSeek V4 Flash as the fallback. Subagents run on DeepSeek V4 Flash. Work is split by what it can be trusted with.

Suitable for DeepSeek V4 Flash:
- Web and datasheet research.
- Log and build-output digging.
- Running make/test targets and reporting the numbers.
- C firmware tasks with a test that decides done.
- Doc edits whose content is already specified.
- Reading document screenshots, datasheet figures and board photos.

Not suitable:
- Writing or debugging SystemVerilog.
- Anything touching fixed-point arithmetic or timing.
- Architecture decisions.
- PR review verdicts.

A subagent's output is delivered to the lead agent, never to a commit or a PR. The lead agent verifies before acting on it.

If any DeepSeek agent finds itself editing RTL, it stops and reports instead.

# Finding your feet

- **The words:** `docs/glossary.md` defines every term the project uses in its own sense; a term that changes meaning changes there in the same PR.
- **The instrument:** `README.md` (what it is, wiring, build, console, preset storage); `docs/design.md` is the single architecture reference and links the rest — `memory_map.md` (control plane, sink words), `csp2_isa.md` / `csp2_architecture.md` (the CSP), `firmware_architecture.md`, `midi_schema.md` / `param_conventions.md` / `control_map.md` (the player's surface), `storage_format.md` (preset files).
- **The tools:** `tools/README.md` says what lives where by what it needs; `tools/lab/README.md` is the guide to driving the board. The build finds ESP-IDF and the CAD suite itself — never source `export.sh`; `tools/esp_idf.sh idf.py …` runs any idf.py command.
- **Two machines:** the cloud box (thj.no, this repo, builds, no board) and the lab box (`ssh -p 23000 thor@home.thj.no`, the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture). Both checkouts rest on `main` and are only ever pulled. Parallel sessions never share a working tree: every session's work, a one-line docs PR included, happens in its own worktree (`git worktree add ~/wt/wt-<issue> -b <branch> main` on the cloud box, the same under `~/wt` on the lab box), which holds its own `rtl/obj_dir`, `yosys.json` and `pnr.log`, so a build never reads another session's branch and a sweep's netlist is the branch it claims. The session that made a worktree removes it when its PR merges.
- **Division of labour:** the cloud box is where the agent lives (always on, static public IP, fast link, the host services, this repo) and where everything that is not a bitstream runs: the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks, the chat. The lab box builds every bitstream (`make pack.fs`: yosys, nextpnr, gowin_pack) and holds the board: its i3-8100B is about 1.5× the cloud box's Neoverse-N1 per core (one placement 6 min against 9, measured Nov 2026) and has four cores to its two, so a seed sweep (`tools/lab/placement_sweep.sh`, four seeds at once, one nextpnr being one thread and about 200 MB) and a board test's bitstream are both made there, never built on the cloud box and shipped over. The cloud box places only when the lab box is down. Seeds remain a diagnostic of the tool, never part of the build. The sweep is a monitor, not a gate (#434): an rtl PR's chain is synthesis, one placement at the default seed, `pack.fs`, the board take, the PR comment with the take and the utilisation lines that moved; the four random draws start after the take, in the background (`REPORT=1 nohup tools/lab/placement_sweep.sh … &`), and when the sweep ends the script posts its verdict as a commit status on the swept commit (context `sweep`), the tick or cross GitHub shows on the commit and on a PR whose head it is, relayed to the chat; a `sweep WARNING` (a draw that failed to place or route, or a floor under 85 MHz) or a `sweep FAIL` (a draw under the clock) also opens an issue under #363 with the table, by the script, whether or not a session is alive (#443). Nothing about a sweep goes on a PR as a comment: the sweep measures a state of the design, not a change. The sweep's placements run at the lowest CPU priority, so a take started during one is not slowed.
