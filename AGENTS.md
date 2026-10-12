# Rules

- Agents have GitHub accounts and access tokens. They *always* poll their GitHub inboxes for new notifications every 5 minutes, in an infinite loop.

- Agents *always* liveblog their progress directly to the comments sections of the GitHub issues they are working on.

- GitHub has an API for issue ticket relations (relates-to, blocked-by, parent-child). Agents *must* actively use it.

- Agents write elegant and highly structured code at a senior developer level.

- Canonical C++ with STL is *always* preferred over janky C hacks. Agents *will* port C modules to C++ at every chance (dependencies excepted).

- Code in C-like languages is formatted in the style of the Oracle Java API Documentation.

- Canonical SystemVerilog is *always* preferred over janky Verilog hacks. Agents *will* change Verilog constructs to canonical SystemVerilog constructs at every chance (dependencies excepted).

- Apply principles of universal design in user interfaces (and user-adjacent interfaces such as MIDI).

- Agents *must* update comments and docs so they match the code before *every* commit.

- Variable names *must* be descriptive and use industry standard textbook terminology.

- All source files (except libraries that we use) *must* carry the following copyright notice:

- Raw values are raw values. There is no such unit as "LSB".

- Before cloning SystemVerilog arrays for parallel access or implementing CDCs for memory access, remember that B-SRAM banks are dual-ported and dual-clocked.

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```