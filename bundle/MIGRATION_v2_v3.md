# Migration SDLCv2 → SDLC v3

Practical guide to migrate an existing project governed by SDLCv2 to the SDLC v3 bundle.
The migration is **manual and optional**.

> **Command namespace**: v2 and v3 both use `/sdlc:*`. Installing the v3 bundle replaces the
> v2 commands in `~/.claude/commands/sdlc/` (the installer backs them up first). Existing v2
> projects keep their files; migrate them with the steps below when you want to use v3 on them.
> Upgrading from v3.x to v4.0: see `MIGRATION_v3_v4.md`.

---

## Structural differences

### Project directory

| v2 | v3 |
|---|---|
| `SDLC_PM/v1.0.0/1_elicitation.md` | `SDLC_PM/v1.0.0/1_elicitation.md` |
| `SDLC_PM/v1.0.0/2_architecture.md` | `SDLC_PM/v1.0.0/2_architecture.md` |
| (none) | `SDLC_PM/v1.0.0/2_5_discussion.md` ← **new** |
| `SDLC_PM/v1.0.0/3_conception.md` | `SDLC_PM/v1.0.0/3_conception.md` (`wave: N` column added) |
| `SDLC_PM/v1.0.0/4_tests.md` | `SDLC_PM/v1.0.0/4_tests.md` |
| `SDLC_PM/SDLC_PLAN.md` | `SDLC_PM/SDLC_PLAN.md` |
| `SDLC_PM/SDLC_ARCH.md` | `SDLC_PM/SDLC_ARCH.md` |
| `SDLC_PM/SDLC_CHECKPOINT.md` | `SDLC_PM/SDLC_CHECKPOINT.md` |
| (none) | `SDLC_PM/sdlc-config.json` ← **new** (project config) |

### ID scheme

**Unchanged**: `E###`, `A###:E###`, `P###:A###`, `T###:P###`. No identifier needs rewriting.

**New field in `3_conception.md`**: a `wave: N` column for each P###. N is an integer ≥ 1
giving the execution wave the task belongs to (computed by `wave_planner.py` with a
topological sort of the dependency DAG).

---

## Manual migration

### Step 1 — Back up

```powershell
Copy-Item -Path "SDLC_PM" -Destination "SDLC_PM.v2-backup" -Recurse
```

### Step 2 — Project layout

v2 and v3 use the same `SDLC_PM/` layout and file names; nothing needs renaming.

### Step 3 — Create the project config

Copy the template:

```powershell
$src = "$HOME/.claude/skills/sdlc/assets/sdlc-config.example.json"
Copy-Item -Path $src -Destination "SDLC_PM/sdlc-config.json"
```

Then edit `sdlc-config.json` for the project (v4.0 fields shown; see `MIGRATION_v3_v4.md`):

```json
{
  "version": "4.0",
  "project_name": "<project-name>",
  "output_language": "en",
  "primary_language": "python",
  "model_profile": "balanced",
  "auto_approve": false,
  "asvs_level": 1,
  "max_retry_per_task": 3,
  "fresh_context_per_task": true,
  "wave_parallelism": true
}
```

### Step 4 — Annotate waves in `3_conception.md`

Add the `wave: N` metadata to each existing P### in the table.

To compute it instead of doing it by hand:

```powershell
$env:PYTHONUTF8 = "1"
python "$HOME/.claude/skills/sdlc-wave-orchestrator/scripts/wave_planner.py" `
  --conception "SDLC_PM/v1.0.0/3_conception.md" --annotate
```

### Step 5 — Discussion phase (retroactive, optional)

To document the key architecture decisions after the fact, create `2_5_discussion.md` from
the template:

```powershell
Copy-Item `
  "$HOME/.claude/skills/sdlc/assets/2_5_discussion.template.md" `
  "SDLC_PM/v1.0.0/2_5_discussion.md"
```

### Step 6 — Validate with the AQ Gate

```powershell
$env:PYTHONUTF8 = "1"
python "$HOME/.claude/skills/sdlc/scripts/check_sdlc.py"
```

Exit code 0 = migration succeeded; the project is ready for `/sdlc:dev`.

---

## Unversioned artifacts

| v2 artifact | In v3 |
|---|---|
| `SDLC_PM/archive/` | Stays in `SDLC_PM/archive/` |
| v2 pre-commit hooks | Reinstall manually (v3 ships no hooks) |
| Customizations of `~/.claude/agents/sdlc/*.md` | Port them to the v3 agents (`~/.claude/agents/sdlc-*.md`) or to a skill's `references/` if relevant |

---

## Rolling back to v2

```powershell
Remove-Item -Path "SDLC_PM" -Recurse -Force
Rename-Item -Path "SDLC_PM.v2-backup" -NewName "SDLC_PM"
```

Then reinstall the v2 commands.

---

## Behavior changes to know

1. **Code Lock**: rule unchanged. No file is modified without a `P###` ✅ in
   `3_conception.md`. v3 also checks that the `wave` field is consistent before unlocking.
2. **AQ Gate**: `check_sdlc.py` v3 is a superset of v2. All v2 checks are kept, plus:
   - validation of the wave DAG (cycle detected → exit 1)
   - ASVS scan when `asvs_level >= 1` in the config
   - validation of the `sdlc-config.json` schema
3. **`/sdlc:dev` execution**: parallelizes through subagents by default (Agent tool, fresh
   context per task). Disable with `wave_parallelism: false` in the config.
4. **`--auto-approve` mode**: new flag for `/sdlc:dev`. The skill skips the Y/N confirmations
   between tasks. Code Lock and the AQ Gate stay active (no file is written without a P### ✅).

---

## FAQ

**Q. My v2 project was Python only. Do I need the lang-dispatcher?**
A. No. `primary_language: "python"` in the config is enough. The lang-dispatcher only matters
when a project mixes several languages.

**Q. Does Code Lock also apply to subagents running in parallel?**
A. Yes. Each subagent checks its P### in `3_conception.md` before writing anything, and the
mutex in `lockfile_helper.py` prevents two subagents from writing `SDLC_PM/STATE.md` at the
same time.

**Q. What happens if the wave DAG contains a cycle?**
A. `check_sdlc.py` (AQ Gate) refuses to pass, and `wave_planner.py` logs the error with the
detected cycle. The design phase cannot be validated until the cycle is broken.
