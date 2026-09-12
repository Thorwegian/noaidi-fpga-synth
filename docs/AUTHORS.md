# Authors & provenance

This repository has been written by two people and two AI coding
agents. GitHub's author attribution is only partly correctable after
the fact (issue and comment authorship cannot be reassigned through
the API; a commit's author is fixed by the email it was made with, and
changing it means rewriting history). This file is the honest map that
the historical record cannot itself carry. Established per issue #99.

## Identities

| Who | GitHub | Notes |
|-----|--------|-------|
| Thor | [@Thorwegian](https://github.com/Thorwegian) | Project owner; hardware, DSP direction, ear tests, decisions. |
| Jens Tore | [@jenstf](https://github.com/jenstf) | Operates the Claude Code agent; relays between Thor and Claude. |
| Claude (Claude Code) | [@noaidi-claude](https://github.com/noaidi-claude) | AI coding agent, operated by @jenstf. Machine account, created 2026-09-12. Commits also carry a `Co-Authored-By: Claude` trailer naming the exact model. |
| Hermes (Hermes Oracle) | *(pending)* | Thor's second AI agent. Its own machine account is its operator's to create; until then its work appears under @Thorwegian. |

## The tangle this file untangles

Before 2026-09-12, neither agent had its own GitHub identity. Both
acted through @Thorwegian's `gh` login, so a large share of the issues,
comments and commits attributed to @Thorwegian were in fact written by
Claude or by Hermes. From 2026-09-12 onward each agent uses its own
account (Claude: @noaidi-claude; Hermes: pending), so new attribution
is correct at the source.

### Reconstructing the past

- **Claude's commits** are identifiable precisely: they carry a
  `Co-Authored-By: Claude ...` trailer. `git log --grep='Co-Authored-By: Claude'`
  enumerates them. These were authored under @Thorwegian's git identity
  before 2026-09-12 and under @noaidi-claude's noreply address after.
- **Claude's issues/comments** filed via @Thorwegian's login cannot be
  reassigned (GitHub API limitation). Where it matters, a provenance
  line is added to the issue body rather than faked.
- **Hermes's contributions** need one enumeration from Hermes's
  operator (issue/commit ranges); appended here when supplied.

### On rewriting commit history

Considered and declined (issue #99): rewriting historical commit
authorship with `git filter-repo` would change every SHA, and the
issue tracker cites commit SHAs densely (milestone merges, fix
references). The integrity of those references is worth more than
retroactive author purity. If ever undertaken, it happens in a quiet
window with a SHA-translation table appended to this file.

## Commit trailer convention

Model-specific `Co-Authored-By` trailers are the durable record of
which model wrote a commit, independent of the account it was pushed
under:

```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

The trailer names the model; the commit author (`@noaidi-claude`'s
noreply address, going forward) names the operated identity.
