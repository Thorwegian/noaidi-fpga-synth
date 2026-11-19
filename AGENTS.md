# Rules

  - Git policies: Agents have GitHub accounts. `gh` access tokens and SSH keys are set up in their home directories. Agents pay attention to what is going on at GitHub as they work: new comments and notifications on the issues and pull requests they are working on. Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. Issue relations live in GitHub's fields, never in prose, and the one relation is parent and sub-issue, read as a Makefile reads a target and its prerequisites: an issue is a sub-issue of the issue that needs it finished. A parent's own work starts when its sub-issues are closed, so the issue to work on is one with no open sub-issues; a parent with no work of its own closes with them. The sub-issues of one parent are a collection, not a sequence: none depends on or blocks another, and they are worked in any order or side by side. Work that has an order is therefore a chain of parent and sub-issue, one unit of work an issue, the unit worked first deepest. Before opening an issue the agent looks for its parent among the open parents (`gh issue list --state open --label meta`, then a search on the topic, `gh issue list --state open --search "<words>"`), and an agent-opened issue has, at creation, its labels and its parent (`gh api -X POST repos/<r>/issues/<parent>/sub_issues -F sub_issue_id=<id>`, the id from `gh api repos/<r>/issues/<n> --jq .id`). Only when no open issue is its parent does the agent open the parent first (labelled `meta`: a body stating the goal and the rule, never a list of its children). The tree is the order of work: no dependency link (`blocked_by`) is made between issues. The field is the only place a relation lives: `gh issue view` prints `parent:` and `sub-issues:` in every issue's header, so "see #n", "sibling of #n", "parent: #n" or "blocked by #n" written in a body or a comment is noise when it agrees with the field and a lie once the issue is re-parented. The body may say why the issue is its parent's prerequisite when the titles do not make it plain; that is a sentence about the design, not a link. A PR's relation to its issue is `Fixes #n` in the PR body. When an agent pull request is approved, the agent must remove the branch it created for it.

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
- **Three machines:** the cloud box (thj.no, this repo, builds, no board), the lab box (`ssh -p 23000 thor@home.thj.no`, the same repo under `~/Documents/Code/noaidi-fpga-synth`, the boards, the audio capture) and the Mac (`ssh -p 23456 hermes@home.thj.no`, an M2 Pro with six performance cores, which is also the machine Thor works at: the agent's account there has no administrator rights, its home is `/Volumes/Media/Hermes`, and it holds the pinned nextpnr, built by hand, in `~/nextpnr-bench/install` and no checkout of this repo). Both checkouts rest on `main` and are only ever pulled. Parallel sessions never share a working tree: every session's work, a one-line docs PR included, happens in its own worktree (`git worktree add ~/wt/wt-<issue> -b <branch> main` on the cloud box, the same under `~/wt` on the lab box), which holds its own `rtl/obj_dir`, `yosys.json` and `pnr.log`, so a build never reads another session's branch and a sweep's netlist is the branch it claims. The session that made a worktree removes it when its PR merges.
- **Division of labour:** the cloud box is where the agent lives (always on, static public IP, fast link, the host services, this repo) and where everything that is not a bitstream runs: the Verilator sims, `make csp-test` and the cosim, the firmware build, the checks, the chat. The lab box builds every bitstream (`make pack.fs`: yosys, nextpnr, gowin_pack) and holds the board: its i3-8100B is about 1.5× the cloud box's Neoverse-N1 per core (one placement 6 min against 9, measured Nov 2026) and has four cores to its two, so a seed sweep (`tools/lab/placement_sweep.sh`, four seeds at once, one nextpnr being one thread and about 200 MB) and a board test's bitstream are both made there, never built on the cloud box and shipped over. The cloud box places only when the lab box is down. Place and route is the Mac's work: four placements side by side end there in under four minutes, where the lab box's four had not ended after nearly nine (the same netlist, seeds and chip database, measured Nov 2026). The build places on the machine it runs on (#465), so a placement for the Mac is carried there by hand (`yosys.json` and `constraints.cst` over, nextpnr with the Makefile's options, `pnr.json` back to the lab box for `gowin_pack` and the take), and the chain described here runs on the lab box. Every job on the Mac is started with `nice -n 20`, which leaves the machine to Thor while it runs and costs nothing when he is away; the job is given the low priority, never the SSH service, since a login at that priority does not get in beside a job on every core. The Mac's nextpnr places against the lab box's `chipdb-GW2A-18C.bin`, copied over the one its own build generates from another Apicula. A seed names a placement only on the machine that ran it. Seeds remain a diagnostic of the tool, never part of the build. The sweep is a monitor, not a gate (#434): an rtl PR's chain is synthesis, one placement at the default seed, `pack.fs`, the board take, the PR comment with the take and the utilisation lines that moved; the four random draws start after the take, in the background (`REPORT=1 nohup tools/lab/placement_sweep.sh … &`), and when the sweep ends the script posts its verdict as a commit status on the swept commit (context `sweep`), the tick or cross GitHub shows on the commit and on a PR whose head it is, relayed to the chat; a `sweep WARNING` (a draw that failed to place or route, or a floor under 85 MHz) or a `sweep FAIL` (a draw under the clock) also opens an issue under #363 with the table, by the script, whether or not a session is alive (#443). Nothing about a sweep goes on a PR as a comment: the sweep measures a state of the design, not a change. The sweep's placements run at the lowest CPU priority, so a take started during one is not slowed.
