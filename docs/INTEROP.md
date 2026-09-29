# Optional interoperability with `nestor-agents`

`sdlc-framework` (this repository) and
[`nestor-agents`](https://github.com/JYHemlin4812/nestor-agents) are **independent** repositories:
each installs and works on its own. Nothing here is required to use the SDLC framework. When both
are installed, they complement each other:

| Topic | Nestor side (`nestor-agents`) | SDLC side (this repository) |
|---|---|---|
| Flow 3 (software development) | `nestor-analyste` routes the request to flow 3 | `/sdlc:*` runs the 9 phases |
| Quality | `nestor-qualite` validates phase deliverables (veto) | AQ Gate (`/sdlc:gate`) checks E→A→P→T traceability |
| Document management | `nestor-archiviste` files and versions artifacts | `sdlc-archive-manager` archives session artifacts (`/sdlc:exit`) |

## Shared documentation convention

- SDLC artifacts live in the target project's `SDLC_PM/` (`HANDOFF.md`, `SDLC_CHECKPOINT.md`,
  `0_context.md`, `1_…4_*.md`, IDs `E###`, `A###`, `P###`, `T###`).
- The Nestor archivist treats them as artifacts **to index without modifying them**:
  identification (project/version), filing, date, link to `SDLC_PM/`.
- The two archivists overlap on purpose: `nestor-archiviste` (all flows) and
  `sdlc-archive-manager` (end of an SDLC session). Neither depends on the other.

## Without the SDLC framework installed

Flow 3 stays defined in `nestor-agents`, but its orchestrator follows the 9 phases (§7 of
`claude/NESTOR.md` in that repository) without the `/sdlc:*` commands. Never invoke an `sdlc-*`
agent that is not installed.

> This file mirrors `docs/INTEROP.md` in the `nestor-agents` repository.
