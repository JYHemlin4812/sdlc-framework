# `--auto-approve` mode (semi-autonomous)

Runs the `brainstorm → plan → dev → gate → report` chain without Y/N confirmations between steps.
Intended for S/M projects where human supervision between phases slows things down without adding
value.

## Activation

Three ways, highest priority first:

1. **CLI flag**: `/sdlc:dev --auto-approve`
2. **Project config**: `auto_approve: true` in `sdlc-config.json`
3. **Environment variable**: `$env:SDLC_AUTO_APPROVE = "1"`

The CLI flag wins over the config, and the config wins over the environment.

## What changes with `--auto-approve`

| Behavior | Without `--auto-approve` | With `--auto-approve` |
|---|---|---|
| Confirmation between phases | Asks Y/N | Skipped, continues |
| Discussion phase (M/L) | Proposed | Skipped (re-enable explicitly) |
| Confirmation before dev | Asks Y/N | Skipped |
| Confirmation before gate | Asks Y/N | Skipped |
| Confirmation before report | Asks Y/N | Skipped |

## What does not change (safeguards stay active)

| Safeguard | State in `--auto-approve` |
|---|---|
| Code Lock | ✅ Always active |
| AQ Gate (`check_sdlc.py`) | ✅ Always blocking |
| Max retries per P### | ✅ Respects `max_retry_per_task` |
| Parallel agent cap | ✅ Respects `max_parallel_agents` |
| Stop on 🚫 | ✅ The run stops on a blocked P### |
| ASVS scan | ✅ Runs when `asvs_level >= 1` |

Autonomy is not permissiveness: structural discipline (Code Lock + AQ Gate) replaces human
supervision only for what it can cover, so auto-approve never disables a safeguard.

## The checklist

In auto-approve mode the progress checklist is the `**Status**` field of each P### in
`3_conception.md` plus `SDLC_PM/STATE.md`. Read them to decide what to do next, and update
them as tasks change state; do not keep a separate plan in the conversation.

## Standing instruction for unattended runs

Apply this only in auto-approve mode, never in interactive mode:

> In auto-approve mode nobody is watching the turn. A message without a tool call ends your turn
> and stops the run. Do not end a turn with (1) a summary that announces the next step instead
> of taking it, (2) an offer to continue "unless you prefer otherwise", (3) a list of decisions
> none of which blocks the remaining work, or (4) a pause because a wave or milestone finished.
> Put status notes in the same message as your next tool call and keep going while `⬜`/`🔁`
> tasks remain. Stop only when every task is ✅ and the AQ Gate passed, when a task becomes 🚫,
> when Code Lock or the AQ Gate refuses progress, or before a destructive/irreversible action
> (these still need the user).

## When auto-approve still stops

Return to the user when:

1. **A P### is marked 🚫** (failure after max retries) — the root cause needs a human.
2. **The AQ Gate fails unexpectedly** — a state the agent cannot repair.
3. **External dependencies are missing** (e.g. Python not found, a package cannot be installed).
4. **A file conflict appears** (a target file was modified outside any P### — Code Lock
   diagnosis).
5. **A DAG cycle is detected** by `wave_planner` — this means a design error that a human must
   resolve.
6. **A destructive or irreversible action** is next (e.g. force push, dropping data).

In every case, log the reason clearly in `STATE.md` and stop, without trying to work around it.

## Usage recommendations

- **S projects**: `--auto-approve` is generally safe; the scope is small and risks contained.
- **M projects**: use `--auto-approve` after a manually validated brainstorm + plan; run only the
  dev phase in auto.
- **L projects**: full auto-approve is not recommended. Prefer running it one segment at a time
  (e.g. one wave) with human review between waves.

## Counters / observability

In auto-approve mode, keep these counters in `STATE.md`:

```yaml
auto_approve:
  enabled: true
  phases_completed: 3
  tasks_completed: 7
  retries_consumed: 2
  escalations: 0
  blocked: 0
  last_action_ts: "2026-05-09T18:42:00Z"
```

They let the user come back and see what happened.

## Step-by-step mode (strict interactive)

The opposite: `--strict-confirm` asks for confirmation before every P### (not only between
phases). Useful for debugging; not recommended for normal use — it is essentially the v2 mode.

```
/sdlc:dev --strict-confirm
```
