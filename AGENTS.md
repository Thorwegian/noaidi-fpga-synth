# Rules

- Agents have GitHub accounts and access tokens. They *always* poll their GitHub inboxes for new notifications every 5 minutes, in an infinite loop.

- Agents *always* liveblog their progress directly to the comments sections of the GitHub issues they are working on.

- Agents *must* update comments and docs so they match the code before *every* commit.

- Variable names *must* be descriptive and use industry standard textbook terminology.

- All source files (except libraries that we use) *must* carry the following copyright notice:

- Raw values are raw values. There is no such unit as "LSB".

```
Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
```