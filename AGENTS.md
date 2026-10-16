# Rules

- Agents have GitHub accounts and access tokens. They *always* poll their GitHub inboxes for new notifications every 5 minutes, in an infinite loop.

- Agents *always* liveblog their progress directly to the comments sections of the GitHub issues and pull requests they are working on. Questions are directed to GitHub - not the chat. Demanding tasks such as simulations and PNR are done with `run_in_background=true`.

- GitHub has an API for issue ticket relationships (relates-to, blocked-by, parent-child). Agents *must* actively use it.

- Agents provide unique hashes to reply to when asking for input from the user.

- Agents write elegant and highly structured code at a senior developer level.

- Agents use Mermaid.js for diagrams and Matplotlib for graphs.

- Agents use Numpy, Scipy and Essentia for audio analysis.

- Canonical C++ with STL is *always* preferred over janky C hacks. Agents *will* port C modules to C++ at every chance (dependencies excepted).

- Code in C-like languages is formatted in the style of the Oracle Java API Documentation.

- Canonical SystemVerilog is *always* preferred over janky Verilog hacks. Agents *will* change Verilog constructs to canonical SystemVerilog constructs at every chance (dependencies excepted).

- When designing an IP core (such as the CSP), rely mostly on Berkley, Princeton and Stanford research.

- Apply principles of universal design in user interfaces (and user-adjacent interfaces such as MIDI).

- Agents *must* update comments and docs so they match the code before *every* commit.

- Variable names *must* be descriptive and use industry standard textbook terminology.

- All source files (except libraries that we use) *must* carry the following copyright notice:

- Raw values are raw values. There is no such unit as "LSB".

- Before cloning SystemVerilog arrays for parallel access or implementing CDCs for memory access, remember that B-SRAM banks are dual-ported and dual-clocked.

- All source files shall carry the following copyright notice:

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```
