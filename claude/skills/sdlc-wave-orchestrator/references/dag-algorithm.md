# Kahn's algorithm (layered topological sort)

Implementation: `scripts/wave_planner.py:kahn_layers`.

## Idea

A DAG (directed acyclic graph) can be linearized by a topological sort. Kahn's
algorithm produces that order in successive layers: at each iteration, remove
the nodes with no incoming dependency (in_degree 0), decrement the in_degree of
their children, and repeat.

In SDLC, each layer is an execution wave. P### tasks in the same layer have no
mutual dependency, so they can run in parallel.

## Pseudo-code

```
function kahn_layers(deps):
    in_degree[node] = len(parents) for each node
    waves = []
    queue = sorted([node for node, d in in_degree if d == 0])
    while queue is not empty:
        layer = sorted(queue)
        waves.append(layer)
        queue = []
        for node in layer:
            for child in children[node]:
                in_degree[child] -= 1
                if in_degree[child] == 0:
                    queue.append(child)
    cycle_nodes = [node for node, d in in_degree if d > 0]
    return waves, cycle_nodes
```

## Complexity

- Time: O(V + E) — each node visited once, each edge traversed once.
- Space: O(V + E) to store the graph and the in_degree map.

On a project with 100 P### and 200 dependencies, it runs in under 10 ms.

## Determinism

Nodes within a layer are sorted by ID (e.g. `["P001", "P002", "P003"]`), so the
result is stable: same DAG, same waves, same order.

This gives:
- a reproducible execution plan;
- easy comparison between two runs (stable diff);
- deterministic writes to `3_conception.md`.

## Cycle detection

If nodes with in_degree > 0 remain after the last iteration, they form a cycle
(or depend on one). They are listed for diagnosis.

Example:

```
P001 → P002 → P003
            ↑     ↓
            └─────┘
```

Here P002 depends on P003 and P003 depends on P002. Neither ever reaches
in_degree 0, so a cycle is detected.

## Alternatives considered (rejected)

- **DFS-based topological sort**: yields a linear order, not layers. Less
  suited to wave parallelism.
- **Critical Path Method (CPM)**: relevant for planning with durations, but we
  have no reliable durations. Over-design.
- **Coffman-Graham scheduling**: optimizes depth under a width constraint, but
  adds complexity our use does not justify (`max_parallel_agents` is already an
  explicit cap).

Kahn is the right fit: simple, fast, deterministic, and sufficient.

## Edge cases handled

- **Empty graph**: returns `(waves=[], cycles=[])`.
- **Self-loop** (`P001 depends on P001`): ignored at parse time
  (`wave_planner.parse_dag` filters it).
- **Dependency on a non-existent P###**: added to the graph with in_degree=0
  (does not break the sort; `check_sdlc.py` reports it).
- **Several roots**: all in wave 1, as expected.
- **Several leaves**: all in the last wave, as expected.

## Reference tests

All covered in `tests/test_wave_planner.py`:

| Test | DAG | Expected result |
|---|---|---|
| linear_chain | P1→P2→P3 | 3 waves × 1 |
| independent_tasks | P1, P2, P3 (no links) | 1 wave × 3 |
| diamond | P1→{P2,P3}→P4 | [P1], [P2,P3], [P4] |
| cycle | P1↔P2 | cycles=[P1,P2] |

## Known limitations

- **No weighting**: all P### in a wave are treated as equivalent. If some take
  10× longer, they are not started first. Acceptable for our use — the
  orchestrator already schedules its subagents sensibly.
- **No dynamic re-planning**: if a P### fails and unblocks or blocks other
  tasks, the waves are not recomputed automatically. Run
  `wave_planner.py --annotate` again.
