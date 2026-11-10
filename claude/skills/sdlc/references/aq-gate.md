# AQ Gate (quality assurance gate)

Source of truth: `scripts/check_sdlc.py`. The gate is **blocking**: a non-zero exit code means no
phase may progress.

## How to run it

```powershell
$env:PYTHONUTF8 = "1"
python skills/sdlc/scripts/check_sdlc.py
# or through the PowerShell wrapper with JSON output:
pwsh skills/sdlc/scripts/check_sdlc.ps1 -Json
```

Equivalent slash command: `/sdlc:gate`.

## Exit codes

| Code | Meaning | Action |
|---|---|---|
| 0 | PASS (or SKIPPED for tier `none`) | Progression allowed. SKIPPED means nothing was checked: it is never reported as PASS |
| 1 | FAIL | Traceability, wave, placeholder or ASVS errors — fix before continuing |
| 2 | ERROR | Invalid `sdlc-config.json` (JSON syntax). The PowerShell wrapper also exits 2 when Python or `check_sdlc.py` is missing |

Warnings (lines starting with `⚠️`) do not change the exit code. The wrapper's JSON output lists them in `warnings`.

## Checks by documentation tier

The gate reads `documentation_tier` from `SDLC_PM/sdlc-config.json`.

| Tier | Version folder | Checks |
|---|---|---|
| `none` | not required | Nothing. Reports SKIPPED, exit 0 |
| `minimal` | not required | `HANDOFF.md` and `RESUME.md` exist and contain no unfilled placeholder. HANDOFF older than 7 days: warning |
| `standard` | required | The minimal checks, plus E→P: `A###` and `T###` are optional. A `P###` may link to an `E###` when no `A###` is written |
| `full` | required | The minimal checks, plus strict E→A→P→T, and `asvs_level >= 1` |
| `exhaustive` | required | As `full`, and `asvs_level >= 2` |
| absent or invalid | required | Strict E→A→P→T, as in earlier versions. No placeholder check (existing projects keep their verdict) |

At every tier except `none` and absent, a template placeholder left unfilled is an error. A placeholder is a line of a document that is identical to a line of the shipped templates and contains `<...>`. Partly filled documents are therefore caught, and a legitimate value such as `<dialog>` is not. A placeholder that spans several lines (for example in `HANDOFF.template.md`) is detected line by line. Fenced code blocks (``` or ~~~, indented by up to three spaces) are examples and are not checked, with one exception: in `RESUME.md` and `HANDOFF.md`, command blocks (`bash`, `sh`, `shell`, `zsh`, `console`, `powershell`, `pwsh`, `cmd`, `bat`) hold required bootstrap steps and are checked like the rest of the document.

### Phases

`check_sdlc.py --phase plan` is the precondition of `/sdlc:dev`. It does not require `4_tests.md` yet: the tests are written during development. `--phase release` (the default) is the full check, run at the end of the waves and before a release.

Version folders are compared by number: `v10.0.0` is newer than `v9.0.0`. Folders whose names do not match `vX.Y.Z` are ignored.

Test coverage is not measured by the gate. `test_coverage_min` is a project target, shown as an indicator in the configuration schema.

## Checks performed (v3+, superset of v2)

### Inherited from v2

1. `SDLC_PM/vX.X.X/` exists (the most recent one is checked)
2. `1_elicitation.md` is not empty and contains ≥ 1 E###
3. Every A### declares an existing parent E### (`A###:E###`)
4. Every P### declares an existing parent A### (`P###:A###`); at tier `standard` with no A###
   written, an existing parent E### (`P###:E###`)
5. Every T### declares an existing parent P### (`T###:P###`)
6. No duplicate ID anywhere
7. No active blocker (`🚫` or `[B]` in the .md files)

### Added in v3

8. **`sdlc-config.json` schema** is valid (when present):
   - `version` ∈ {`"3.0"`, `"3.1"`, `"3.2"`, `"4.0"`}
   - `model_profile` ∈ {budget, balanced, quality, inherit}
   - `asvs_level` ∈ {0, 1, 2, 3}
   - `primary_language` ∈ {python, javascript, typescript, go, rust}
   - `output_language`, when set, is a non-empty string
9. **`**wave**` fields** are present on every P### (integer ≥ 1)
10. **DAG consistency**: no P### depends (`**Depends on**`) on a P### of its own wave or a later
    wave (otherwise the DAG is invalid).
11. **Cycle detection** in the P### DAG (Kahn's algorithm). A cycle → exit 1.
12. **ASVS scan** when `asvs_level >= 1`: runs `sdlc-asvs-auditor/scripts/asvs_scanner.py`.
    Undocumented high-severity findings → exit 1.

## Report layout

```
--- AQ SDLC — Version: v1.0.0 ---

(detailed checks, one ❌ per error)

🚫 AQ FAIL — N error(s). Fix them before continuing.
```

or on success:

```
--- AQ SDLC — Version: v1.0.0 ---

✅ AQ PASS — v1.0.0 validated. Ready for the next step.
```

The exact wording comes from `check_sdlc.py`; the samples here are illustrative.

## JSON output (via `check_sdlc.ps1 -Json`)

```json
{
  "timestamp": "2026-05-09T18:30:00Z",
  "status": "FAIL",
  "exitCode": 1,
  "message": "AQ Gate failed: 2 error(s)",
  "errors": [
    "❌ Orphan A### (parent E### does not exist): ['A005']",
    "❌ Cycle detected in the P### DAG: ['P003', 'P004', 'P005']"
  ],
  "projectRoot": "C:\\dev\\myproject"
}
```

Suitable for a pre-commit hook or a CI/CD step.

## Diagnosing common errors

### Orphan A### (parent E### does not exist)

Cause: an `A042:E099` references an E099 that does not appear in `1_elicitation.md`.

Fix: either add E099 to `1_elicitation.md`, or correct the parent number in `2_architecture.md`.

### P### without a `wave` field

Cause: a P### was added by hand without `- **wave**: N`.

Fix: run `wave_planner.py --conception <path> --annotate` to recompute the waves from the
dependencies.

### Cycle detected in the P### DAG

Cause: `P003` depends on `P005` AND `P005` depends on `P003`.

Fix: break the dependency — often by introducing an intermediate P### that holds the shared part,
or by revisiting the breakdown.

### Active blocker detected in X.md (🚫 or [B])

Cause: a P### was marked 🚫 (failure after max retries) and has not been resolved.

Fix: `/sdlc:fix <P###>` to retry, or remove the 🚫 by hand once the root cause has been analyzed
and resolved.

## Pre-commit hook (optional)

Suggested `.git/hooks/pre-commit` for development commits. It runs the planning phase, so a commit
for a finished task is not blocked by tests that later tasks have not written yet (inspection 9,
AQG-001). The release gate (`-Phase release`, the default) must run before a merge or a release.

```bash
#!/usr/bin/env bash
pwsh skills/sdlc/scripts/check_sdlc.ps1 -Json -Phase plan > /tmp/aq.json
status=$(python -c "import json; print(json.load(open('/tmp/aq.json'))['status'])")
# SKIPPED (tier none) lets the commit through; it is not a PASS and the report says so.
if [ "$status" != "PASS" ] && [ "$status" != "SKIPPED" ]; then
  echo "❌ AQ Gate FAIL — commit refused"
  cat /tmp/aq.json
  exit 1
fi
```
