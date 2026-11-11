"""wave_planner.py — Compute SDLC execution waves.

Reads `3_conception.md`, extracts the DAG of P### tasks and their dependencies,
and applies Kahn's algorithm (layered topological sort) to produce the waves.
Optionally annotates the file with the computed wave numbers.

Field markers: both the English markers (`**Depends on**`, `**Target files**`)
and the legacy French markers (`**Dépend de**`, `**Fichiers cibles**`) are
accepted, so design files written with earlier framework versions still parse.

Outputs:
  - JSON on stdout (default): {"waves": [["P001","P002"], ["P003"], ...],
                               "cycles": [[...]] (empty when there is no cycle),
                               "write_conflicts": [...] (Bernstein linter,
                               empty when there is no intra-wave write conflict)}
  - With --annotate: rewrites 3_conception.md with synchronized `wave: N` fields.

Bernstein linter (W∩W): reports, without blocking, P### tasks of the SAME wave
whose declared write-sets (`**Target files**` field) overlap — two parallel
subagents would then edit the same file. Informational only: it never changes
the exit code.

Exit codes:
  0 — Success, no cycle
  1 — Cycle detected
  2 — Input error (file not found, unparseable)

Usage:
  python wave_planner.py --conception SDLC_PM/v1.0.0/3_conception.md
  python wave_planner.py --conception ...md --annotate
  python wave_planner.py --conception ...md --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict, deque
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


SECTION_RE = re.compile(r"^####\s+(P\d{3})", re.MULTILINE)
# Same line only: `\s` would let an empty value read the next lines (AQ-EDGE-001).
DEPENDS_RE = re.compile(r"\*\*(?:Depends on|D[ée]pend de)\*\*[ \t]*:[ \t]*([^\n]*)", re.IGNORECASE)
FILES_RE = re.compile(r"\*\*(?:Target files|Fichiers cibles)\*\*[ \t]*:[ \t]*([^\n]*)", re.IGNORECASE)
# Horizontal whitespace only: `\s` would cross line breaks (and a masked code block) (AQG-101).
WAVE_LINE_RE = re.compile(r"^([ \t]*[-*][ \t]*\*\*wave\*\*[ \t]*:[ \t]*)\d+", re.MULTILINE)
PID_RE = re.compile(r"\bP\d{3}\b")

# Write-set values treated as "not declared" (the linter stays silent).
# French values are kept for legacy design files.
_EMPTY_FILE_TOKENS = {"none", "aucun", "aucune", "—", "-", "n/a", "na"}

# Fenced code blocks (``` or ~~~) hold examples, never tasks (IR-001). Same pattern as
# check_sdlc.CODE_FENCE, pinned by a test in sdlc/tests: a closing fence repeats the opening
# character only, so ```~ does not close ``` (AQ-REV-101).
FENCE_RE = re.compile(
    r"^[ \t]{0,3}(`{3,}(?=[^`\n]*$)|~{3,})([^\n]*)\n(.*?)(?:^[ \t]{0,3}\1(?:(?<=`)`*|(?<=~)~*)[ \t]*$|\Z)",
    re.DOTALL | re.MULTILINE,
)


def mask_code(content: str) -> str:
    """Blank every fenced code block, keeping offsets and line breaks.

    Parsing runs on the masked text, so an example `#### P999` or `**Depends on**`
    inside a block is never read; positions still map back to the original text.
    """
    return FENCE_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), content)


def parse_dag(content: str) -> dict[str, set[str]]:
    """Return {pid: set_of_parent_pids}."""
    deps: dict[str, set[str]] = {}
    sections = SECTION_RE.split(mask_code(content))
    for i in range(1, len(sections), 2):
        pid = sections[i]
        body = sections[i + 1] if i + 1 < len(sections) else ""
        deps.setdefault(pid, set())
        match = DEPENDS_RE.search(body)
        if not match:
            continue
        raw = match.group(1)
        if "aucun" in raw.lower() or raw.strip() in {"—", "-", ""}:
            continue
        for parent in PID_RE.findall(raw):
            if parent != pid:
                deps[pid].add(parent)
    return deps


def parse_write_sets(content: str) -> dict[str, set[str]]:
    """Return {pid: set_of_normalized_paths} from the `**Target files**` field
    (legacy: `**Fichiers cibles**`) — the *declared* write-set of each P###.

    Silent linter: a missing field, a placeholder (`<...>`) or an empty value
    (`none`, `aucun`, `—`, …) yields an empty set, so that P### never
    conflicts. Path separators are normalized (`\\` → `/`) for consistent
    cross-platform comparison; case is preserved.
    """
    write_sets: dict[str, set[str]] = {}
    sections = SECTION_RE.split(mask_code(content))
    for i in range(1, len(sections), 2):
        pid = sections[i]
        body = sections[i + 1] if i + 1 < len(sections) else ""
        write_sets.setdefault(pid, set())
        match = FILES_RE.search(body)
        if not match:
            continue
        for token in match.group(1).split(","):
            path = token.strip().strip("`").strip()
            if not path or "<" in path or ">" in path:
                continue
            if path.lower() in _EMPTY_FILE_TOKENS:
                continue
            write_sets[pid].add(path.replace("\\", "/"))
    return write_sets


def detect_write_conflicts(
    waves: list[list[str]], write_sets: dict[str, set[str]]
) -> list[dict]:
    """Bernstein linter (condition W₁∩W₂=∅).

    Reports pairs of P### in the **same** wave whose declared write-sets
    overlap: two parallel subagents would write the same file (potential merge
    conflict). Non-blocking — informational only.

    Never compares P### from different waves: the DAG already orders them, so
    they never write concurrently. Deterministic output (pairs and files sorted).
    """
    conflicts: list[dict] = []
    for wave_index, layer in enumerate(waves, start=1):
        members = sorted(layer)
        for a in range(len(members)):
            for b in range(a + 1, len(members)):
                pi, pj = members[a], members[b]
                shared = write_sets.get(pi, set()) & write_sets.get(pj, set())
                if shared:
                    conflicts.append(
                        {
                            "wave": wave_index,
                            "tasks": [pi, pj],
                            "files": sorted(shared),
                        }
                    )
    return conflicts


def kahn_layers(deps: dict[str, set[str]]) -> tuple[list[list[str]], list[str]]:
    """Layered topological sort using Kahn's algorithm.

    Returns (waves, cycle_nodes).
    waves: list of waves; each wave is a list of pids that can run in parallel.
    cycle_nodes: remaining pids when a cycle is detected (empty otherwise).
    """
    in_degree: dict[str, int] = {pid: 0 for pid in deps}
    children: dict[str, list[str]] = defaultdict(list)
    for pid, parents in deps.items():
        for parent in parents:
            if parent in in_degree:
                in_degree[pid] += 1
                children[parent].append(pid)
            else:
                in_degree[pid] += 1
                children.setdefault(parent, []).append(pid)
                in_degree.setdefault(parent, 0)

    waves: list[list[str]] = []
    queue = deque(sorted(pid for pid, d in in_degree.items() if d == 0))
    processed = 0
    total = len(in_degree)
    while queue:
        layer = sorted(queue)
        queue.clear()
        waves.append(layer)
        processed += len(layer)
        next_layer = set()
        for node in layer:
            for child in children.get(node, []):
                in_degree[child] -= 1
                if in_degree[child] == 0:
                    next_layer.add(child)
        queue.extend(sorted(next_layer))
    cycle_nodes = sorted(pid for pid, d in in_degree.items() if d > 0)
    if cycle_nodes:
        return waves, cycle_nodes
    if processed != total:  # defensive
        cycle_nodes = sorted(set(in_degree) - {pid for layer in waves for pid in layer})
        return waves, cycle_nodes
    return waves, []


def annotate_file(path: Path, waves: list[list[str]]) -> None:
    """Rewrite the file, updating the `- **wave**: N` line of each P###."""
    pid_to_wave = {pid: i + 1 for i, layer in enumerate(waves) for pid in layer}
    content = path.read_text(encoding="utf-8")
    masked = mask_code(content)  # sections are found outside code blocks only
    headers = list(SECTION_RE.finditer(masked))
    rebuilt: list[str] = []
    pos = 0
    for idx, header in enumerate(headers):
        end = headers[idx + 1].start() if idx + 1 < len(headers) else len(content)
        rebuilt.append(content[pos:header.start()])
        rebuilt.append(content[header.start():header.end()])
        body = content[header.end():end]
        wave = pid_to_wave.get(header.group(1))
        if wave is not None:
            hit = WAVE_LINE_RE.search(masked[header.end():end])
            if hit:
                # Replace only the number, at its offsets in the original text (AQG-101).
                body = body[:hit.end(1)] + str(wave) + body[hit.end():]
            else:
                # After the whole heading line, so `P001:A001 — Title` stays intact (AQ-REV-202).
                eol = body.find("\n")
                if eol == -1:
                    body = f"{body}\n- **wave** : {wave}\n"
                else:
                    body = f"{body[:eol + 1]}- **wave** : {wave}\n{body[eol + 1:]}"
        rebuilt.append(body)
        pos = end
    rebuilt.append(content[pos:])
    path.write_text("".join(rebuilt), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Compute SDLC execution waves.")
    parser.add_argument("--conception", required=True, help="Path to 3_conception.md")
    parser.add_argument("--annotate", action="store_true", help="Update wave: N in the file")
    parser.add_argument("--json", action="store_true", help="JSON output (on by default)")
    args = parser.parse_args()

    path = Path(args.conception)
    if not path.exists():
        print(f"❌ File not found: {path}", file=sys.stderr)
        return 2

    content = path.read_text(encoding="utf-8")
    deps = parse_dag(content)
    if not deps:
        print(json.dumps({"waves": [], "cycles": [], "message": "No P### found"}, ensure_ascii=False))
        return 0

    waves, cycles = kahn_layers(deps)
    write_sets = parse_write_sets(content)
    write_conflicts = detect_write_conflicts(waves, write_sets)

    if args.annotate and not cycles:
        annotate_file(path, waves)

    payload = {
        "conception": str(path),
        "total_tasks": len(deps),
        "wave_count": len(waves),
        "waves": waves,
        "cycles": cycles,
        "write_conflicts": write_conflicts,
        "annotated": args.annotate and not cycles,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))

    return 1 if cycles else 0


if __name__ == "__main__":
    sys.exit(main())
