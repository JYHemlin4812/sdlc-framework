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
| 0 | PASS | Progression allowed |
| 1 | FAIL | Traceability, wave or ASVS errors — fix before continuing |
| 2 | ERROR | Invalid config, missing dependencies — diagnose |

## Checks performed (v3+, superset of v2)

### Inherited from v2

1. `SDLC_PM/vX.X.X/` exists (the most recent one is checked)
2. `1_elicitation.md` is not empty and contains ≥ 1 E###
3. Every A### declares an existing parent E### (`A###:E###`)
4. Every P### declares an existing parent A### (`P###:A###`)
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

Suggested `.git/hooks/pre-commit`:

```bash
#!/usr/bin/env bash
pwsh skills/sdlc/scripts/check_sdlc.ps1 -Json > /tmp/aq.json
status=$(python -c "import json; print(json.load(open('/tmp/aq.json'))['status'])")
if [ "$status" != "PASS" ]; then
  echo "❌ AQ Gate FAIL — commit refused"
  cat /tmp/aq.json
  exit 1
fi
```
