---
name: sdlc-wave-orchestrator
description: |
  SDLC sub-skill: orchestrates parallel execution of P### tasks in waves.
  Reads `3_conception.md`, computes the topological DAG (Kahn), spawns one
  subagent per P### in parallel for each wave, and guards STATE.md with an
  O_EXCL lockfile mutex.

  Use it during `/sdlc:dev`, or whenever the waves of a `3_conception.md` file
  need to be computed or recomputed. Triggers: parallel execution, SDLC waves,
  wave orchestration, parallel SDLC, task DAG, topological sort, Kahn algorithm.
  Also triggers on (FR): exécution parallèle, vagues SDLC, DAG topologique tâches.
---

# sdlc-wave-orchestrator — parallel execution in waves

Included in the SDLC bundle (installable via `scripts/install.ps1` or
`scripts/install.sh`). This sub-skill holds the parallelism mechanics of SDLC:
computing waves from the P### DAG, launching subagents in batches, and
synchronizing between waves through a lockfile.

## When to use it

- At the start of `/sdlc:dev`, to find the next wave to run.
- During `/sdlc:plan`, to annotate `wave: N` automatically after the P###
  breakdown.
- For diagnosis: to inspect a project's DAG and detect a cycle.

## Tools

- `scripts/wave_planner.py` — parses `3_conception.md`, computes the waves,
  optionally annotates the file. Accepts the English field markers
  (`**Depends on**`, `**Target files**`) and the legacy French ones
  (`**Dépend de**`, `**Fichiers cibles**`).
- `scripts/lockfile_helper.py` — atomic mutex (O_EXCL) for concurrent
  mutations of `STATE.md`.

## Wave computation (Kahn's algorithm)

Details in `references/dag-algorithm.md`. Summary:

```
For each P###, read its dependency list "Depends on: Pxxx, Pyyy".
in_degree[P] = number of dependencies
Wave 1 = {P | in_degree[P] = 0}
For each P in wave 1, decrement the in_degree of its children
Wave 2 = {P | in_degree[P] reached 0 after wave 1}
... repeat until exhausted
If some P still has in_degree > 0: cycle detected → ERROR
```

O(V+E). The order is deterministic (P### inside a wave are sorted by ID).

## Subagent spawning protocol

Delegate one P### per subagent: each task is sizeable and independent of the
others in its wave, which is what makes a fresh context worth its cost. Keep
work that takes only a handful of tool calls (reading STATE.md, updating a
status, re-running `wave_planner.py`) in the orchestrator, and do not spawn
subagents to double-check a result the orchestrator can read directly.

For each wave:

1. Acquire the lockfile on `SDLC_PM/STATE.md.lock` (timeout 10 s).
2. Read `STATE.md` and list the P### of the wave to launch.
3. Release the lockfile, otherwise the subagents block on it.
4. For each P### of the wave, never more than `max_parallel_agents` at a time
   (from `SDLC_PM/sdlc-config.json`):
   - resolve `subagent_type` with `sdlc-lang-dispatcher`
     (`sdlc-python-dev`, `sdlc-js-dev`, `sdlc-go-dev`, `sdlc-rust-dev`);
   - resolve the model with `model_profiler.py resolve --agent <name>`;
   - spawn `Agent(subagent_type=..., model=..., prompt=...)` with the prompt
     below. Send all spawns of a batch in a single message so they run
     concurrently.
5. Wait until every subagent of the batch has returned (the Agent tool returns
   when the subagent hands back).
6. For each result, re-acquire the lockfile, write the final status
   (✅/🔁/🚫) to `STATE.md`, then release it.
7. When every P### of the wave is ✅, move to the next wave. Otherwise handle
   retries and escalation according to the mode (interactive or
   `--auto-approve`).

Lock details: `references/lockfile-protocol.md`.

### P### subagent prompt

Fill in the placeholders; keep the rest as is.

```
You implement task {P###} of the SDLC project in {project_root}.

Context to read first:
- SDLC_PM/{version}/3_conception.md, section {P###} (goal, Target files,
  Depends on, acceptance criteria)
- the A### and E### it traces to (2_architecture.md, 1_elicitation.md)
- the T### cases that cover it (4_tests.md)
- the language standards: {standards_reference}

Time matters here: avoid work that isn't needed, and the earlier a correct
result lands, the better.

Deliver what the task asks, at the scope intended. Make routine judgment calls
yourself. If the task looks mistaken or a better approach exists, say so in one
sentence and continue as asked. Out-of-scope bugs are recorded (see Code Lock),
not fixed silently. Edit only the files listed in Target files, because other
subagents of the same wave may be writing elsewhere in parallel.

Write artifact content and user-facing messages in the project's
`output_language` (`SDLC_PM/sdlc-config.json`; if absent, the language the user
writes in). Keep IDs, template headings and field markers in English.

Run the T### tests for this task and quote the command and its result. Mark the
task ✅ only when they pass. Before marking it 🚫, state the root-cause
hypothesis and the evidence in the task notes, then escalate.

Hand back: final status (✅ / 🔁 / 🚫), files changed, test command and
result, and any out-of-scope issue you recorded.
```

## DAG examples

### Linear chain (little parallelism)

```
3_conception.md:
P001 (deps: none)
P002 (deps: P001)
P003 (deps: P002)

→ Wave 1: [P001]
→ Wave 2: [P002]
→ Wave 3: [P003]
```

No parallel gain — that is fine; some projects are naturally linear.

### Diamond (moderate parallelism)

```
P001 (deps: none)
P002 (deps: P001)
P003 (deps: P001)
P004 (deps: P002, P003)

→ Wave 1: [P001]
→ Wave 2: [P002, P003]   ← parallel
→ Wave 3: [P004]
```

### Many independent tasks (high parallelism)

```
P001..P010 (deps: none)
P020 (deps: P001..P010)

→ Wave 1: [P001..P010]   ← 10 subagents in parallel (capped by max_parallel_agents)
→ Wave 2: [P020]
```

With `max_parallel_agents = 4`, wave 1 runs in batches of 4 (three sequential
batches of 4 + 4 + 2, with 4 subagents running at once in each batch).

## Cycle detection

When `wave_planner.py` detects a cycle, it:

1. returns exit code 1;
2. lists the P### involved in the cycle (e.g. `["P003", "P004", "P005"]`);
3. does not annotate the file, so the problem stays visible.

The AQ Gate refuses to PASS until the cycle is broken.

To break a cycle:

1. Find the redundant dependency (often one added "for convenience" that is
   not really needed).
2. Either remove it,
3. or factor the shared part into a new intermediate P###.
4. Run `wave_planner.py --annotate` again.

## Bernstein linter (intra-wave write conflicts)

Wave computation only knows the declared dependencies (`**Depends on**`). The
blind spot: two P### that write the same file without a declared dependency
land in the same wave, so two subagents edit that file in parallel and produce
a merge conflict.

`wave_planner.py` therefore applies Bernstein's first condition
(`W₁ ∩ W₂ = ∅`) as an assisting linter: it compares the declared write-sets of
the P### in a wave and reports overlaps. The write-set is read from the
optional `**Target files**` field of each P### (comma-separated relative
paths; the legacy `**Fichiers cibles**` marker is also accepted).

Properties:

- Non-blocking: results go to the `write_conflicts` key of the JSON; the exit
  code is unchanged (0 = OK, 1 = cycle, 2 = error). No effect on the AQ Gate —
  it informs a decision and never blocks automatically.
- Silent by default: a P### without `Target files`, with the unfilled
  `<relative paths>` placeholder, or with an empty value (`none`, `—`) is
  ignored.
- Intra-wave only: P### from different waves are never reported, because the
  DAG already orders them.
- Granularity: exact path (separators `\` → `/` normalized; case preserved).

Conflict format:

```json
"write_conflicts": [
  {"wave": 1, "tasks": ["P001", "P002"], "files": ["src/app.py"]}
]
```

To resolve a reported conflict:

1. declare a dependency between the two P### (serializes them into separate
   waves), or
2. isolate each subagent in a git worktree (Agent tool,
   `isolation: "worktree"`) and merge after the wave, or
3. accept the risk knowingly (e.g. edits to disjoint sections of the same
   file).

## Disabling parallelism

With `wave_parallelism: false` in the config:

- waves are still computed (DAG validation);
- they run sequentially, one P### at a time, even when a wave could run in
  parallel.

Useful for debugging, strictly cost-controlled environments, or projects where
a deterministic order makes reviews easier.

## Validation

Unit tests in `tests/test_wave_planner.py` cover linear, independent, diamond
and cycle DAGs, parsing with English and legacy French markers, annotation, and
the Bernstein linter (write-set parsing, ignored placeholder, intra-wave
conflict, no conflict, cross-wave independence).

Run: `python -m pytest tests/ -v`.

## Further reading

- `references/dag-algorithm.md` — Kahn's algorithm in detail
- `references/lockfile-protocol.md` — mutex protocol for STATE.md
- `../sdlc/SKILL.md` — main orchestrator that invokes this sub-skill
