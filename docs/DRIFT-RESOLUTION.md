# Drift resolution — baseline E001 (SP1)

> Historical record (SP1 baseline, 2026-07-01). Kept for traceability; it describes the state
> before this repository became the single source.

**Decision: canonical source = `~/.claude` (the deployed version).** The baseline captures
`~/.claude`, never the legacy development bundle (an outdated subset of it).

## Evidence (recon + verification, 2026-07-01)

- **Strict superset**: `~/.claude` carried **10** `sdlc*` skills; the legacy bundle had only **8**.
  The 2 exclusive ones — `sdlc-receive-review`, `sdlc-verify` — were **not versioned anywhere
  else**.
- **8 source files** newer/more complete on the `~/.claude` side (including
  `agents/sdlc-system-analyst.md`, `skills/sdlc/SKILL.md`,
  `wave-orchestrator/{SKILL.md, scripts/wave_planner.py}`) — deliberate changes made after the
  2026-05-23 install.
- **Nothing significant** only on the bundle side (just 5 `.pyc` caches, discarded).
- **AQ Gate**: captured at **v3.0** (`claude/skills/sdlc/scripts/check_sdlc.py`, 332 lines,
  `SUPPORTED_CONFIG_VERSIONS = {3.0,3.1,3.2}`). The obsolete **v2.0** (160 lines, outside the
  bundle) is **not** captured.

## Not allowed (at the time)

Reinstalling `~/.claude` from the legacy bundle: it would have regressed the 8 files and removed
the 2 unique skills.

## Follow-up

Back-porting the canonical content to a development bundle was **not** done. Decision D3
(repository owner): **`sdlc-framework` becomes the single source**, and the legacy development
bundle is **deprecated** (P010).
