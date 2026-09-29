"""check_sdlc.py — SDLC AQ validator (superset of v2.0).

Extends the v2 checks (E→A→P→T chain, ID:PARENT format, blockers) with the
v3+ checks:

  - Reads SDLC_PM/
  - Validates the sdlc-config.json schema (when present)
  - Validates the `wave: N` field in 3_conception.md
  - Detects cycles in the P### DAG
  - Runs the ASVS scan when asvs_level >= 1 in the config (via asvs_scanner)

Field markers are accepted in English (`**Depends on**`) and in the legacy
French form (`**Dépend de**`) so older projects keep validating.

Exit codes:
  0 — PASS
  1 — FAIL (traceability, schema, wave or ASVS errors)
  2 — ERROR (invalid config, missing dependencies)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


CHAIN_FILES = {
    "E": "1_elicitation.md",
    "A": "2_architecture.md",
    "P": "3_conception.md",
    "T": "4_tests.md",
}

PARENT_MAP = {"A": "E", "P": "A", "T": "P"}

ID_PATTERN = re.compile(r"\b([EAPT]\d{3})\b")
PARENT_PATTERN = re.compile(r"\b([APT]\d{3}):([EAPT]\d{3})\b")
WAVE_PATTERN = re.compile(r"^\s*[-*]\s*\*\*wave\*\*\s*:\s*(\d+)", re.MULTILINE)
WAVE_TABLE_PATTERN = re.compile(r"\|\s*(P\d{3})\s*\|[^|]*\|\s*(\d+)\s*\|")


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


def extract_ids(content: str, prefix: str) -> set[str]:
    return {m for m in ID_PATTERN.findall(content) if m.startswith(prefix)}


def extract_parent_links(content: str, child_prefix: str) -> dict[str, str]:
    links: dict[str, str] = {}
    for child, parent in PARENT_PATTERN.findall(content):
        if child.startswith(child_prefix):
            links[child] = parent
    return links


def extract_waves(content: str) -> dict[str, int]:
    """Return the wave number of each P### in 3_conception.md.

    Reads the summary table first (| P001 | ... | 1 |), then the detailed
    sections (- **wave**: N), which take precedence.
    """
    waves: dict[str, int] = {}
    for pid, wave in WAVE_TABLE_PATTERN.findall(content):
        waves[pid] = int(wave)
    sections = re.split(r"^####\s+(P\d{3})", content, flags=re.MULTILINE)
    for i in range(1, len(sections), 2):
        pid = sections[i]
        body = sections[i + 1] if i + 1 < len(sections) else ""
        match = WAVE_PATTERN.search(body)
        if match:
            waves[pid] = int(match.group(1))
    return waves


def load_config(project_root: Path) -> dict:
    """Load sdlc-config.json from SDLC_PM/. Return {} when absent."""
    config_path = project_root / "SDLC_PM" / "sdlc-config.json"
    if not config_path.exists():
        return {}
    try:
        return json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"❌ Invalid sdlc-config.json: {exc}") from exc


SUPPORTED_CONFIG_VERSIONS = {"3.0", "3.1", "3.2", "4.0"}
SUPPORTED_DOCUMENTATION_TIERS = {"none", "minimal", "standard", "full", "exhaustive"}
SUPPORTED_PROJECT_SIZES = {"one-liner", "small", "medium", "large", "colossal"}


def validate_config_schema(config: dict, errors: list[str]) -> None:
    """Minimal config schema validation (no jsonschema dependency)."""
    if not config:
        return
    version = config.get("version")
    if version not in SUPPORTED_CONFIG_VERSIONS:
        errors.append(
            f"sdlc-config.json: version must be one of {sorted(SUPPORTED_CONFIG_VERSIONS)}, "
            f"got {version!r}"
        )
    profile = config.get("model_profile", "balanced")
    if profile not in {"budget", "balanced", "quality", "inherit"}:
        errors.append(f"sdlc-config.json: invalid model_profile {profile!r}")
    asvs = config.get("asvs_level", 1)
    if asvs not in {0, 1, 2, 3}:
        errors.append(f"sdlc-config.json: asvs_level must be 0, 1, 2 or 3, got {asvs!r}")
    lang = config.get("primary_language")
    if lang and lang not in {"python", "javascript", "typescript", "go", "rust", "powershell", "bash"}:
        errors.append(f"sdlc-config.json: invalid primary_language {lang!r}")
    tier = config.get("documentation_tier")
    if tier is not None and tier not in SUPPORTED_DOCUMENTATION_TIERS:
        errors.append(
            f"sdlc-config.json: invalid documentation_tier {tier!r}, "
            f"expected one of {sorted(SUPPORTED_DOCUMENTATION_TIERS)}"
        )
    out_lang = config.get("output_language")
    if out_lang is not None and (not isinstance(out_lang, str) or not out_lang.strip()):
        errors.append(f"sdlc-config.json: output_language must be a non-empty string, got {out_lang!r}")
    size = config.get("project_size_estimate")
    if size is not None and size not in SUPPORTED_PROJECT_SIZES:
        errors.append(
            f"sdlc-config.json: invalid project_size_estimate {size!r}, "
            f"expected one of {sorted(SUPPORTED_PROJECT_SIZES)}"
        )


def validate_waves(content_p: str, p_ids: set[str], errors: list[str]) -> dict[str, int]:
    """Check that the wave fields in 3_conception.md are consistent."""
    waves = extract_waves(content_p)
    if not p_ids:
        return waves
    missing = [pid for pid in p_ids if pid not in waves]
    if missing:
        errors.append(f"P### without a `wave: N` field: {sorted(missing)}")
    bad = [pid for pid, w in waves.items() if w < 1]
    if bad:
        errors.append(f"P### with wave < 1: {sorted(bad)}")
    return waves


def detect_dag_cycles(content_p: str, waves: dict[str, int], errors: list[str]) -> None:
    """Check wave ordering and detect dependency cycles (Kahn's algorithm).

    Expected dependency line: `- **Depends on** : P001, P002` (the legacy
    French marker `**Dépend de**` is also accepted).
    """
    deps: dict[str, set[str]] = {pid: set() for pid in waves}
    sections = re.split(r"^####\s+(P\d{3})", content_p, flags=re.MULTILINE)
    dep_pattern = re.compile(r"\*\*(?:Depends on|D[ée]pend de)\*\*\s*:\s*([^\n]+)", re.IGNORECASE)
    for i in range(1, len(sections), 2):
        pid = sections[i]
        body = sections[i + 1] if i + 1 < len(sections) else ""
        match = dep_pattern.search(body)
        if not match:
            continue
        raw = match.group(1)
        for parent in re.findall(r"\bP\d{3}\b", raw):
            if parent != pid:
                deps.setdefault(pid, set()).add(parent)

    for pid, parents in deps.items():
        if pid not in waves:
            continue
        for parent in parents:
            if parent not in waves:
                continue
            if waves[parent] >= waves[pid]:
                errors.append(
                    f"{pid} (wave {waves[pid]}) depends on {parent} (wave {waves[parent]}) — "
                    "a dependency must be in a strictly earlier wave"
                )

    in_degree = {pid: 0 for pid in deps}
    for pid, parents in deps.items():
        for parent in parents:
            if parent in in_degree:
                in_degree[pid] += 1
    queue = [pid for pid, d in in_degree.items() if d == 0]
    visited = 0
    while queue:
        node = queue.pop()
        visited += 1
        for child, parents in deps.items():
            if node in parents:
                in_degree[child] -= 1
                if in_degree[child] == 0:
                    queue.append(child)
    if visited < len(deps):
        cycle_nodes = [pid for pid, d in in_degree.items() if d > 0]
        errors.append(f"Cycle detected in the P### DAG: {sorted(cycle_nodes)}")


def run_asvs_scan(project_root: Path, level: int, errors: list[str]) -> None:
    """Run asvs_scanner.py when asvs_level >= 1."""
    if level <= 0:
        return
    scanner = Path(__file__).parent.parent.parent / "sdlc-asvs-auditor" / "scripts" / "asvs_scanner.py"
    if not scanner.exists():
        errors.append(f"asvs_scanner.py not found at {scanner} (asvs_level={level})")
        return
    import subprocess

    try:
        result = subprocess.run(
            [sys.executable, str(scanner), "--level", str(level), "--root", str(project_root)],
            capture_output=True,
            text=True,
            check=False,
            encoding="utf-8",
        )
        if result.returncode != 0:
            errors.append(f"ASVS L{level} scan reported findings:\n{result.stdout}\n{result.stderr}")
    except Exception as exc:  # pragma: no cover
        errors.append(f"Failed to run asvs_scanner.py: {exc}")


def check_traceability(project_root: Path | None = None) -> int:
    project_root = project_root or Path.cwd()
    sdlc_dir = project_root / "SDLC_PM"
    if not sdlc_dir.exists():
        print(f"❌ Error: folder {sdlc_dir} not found.")
        return 1

    versions = sorted(
        (d for d in sdlc_dir.iterdir() if d.is_dir() and d.name.startswith("v")),
        key=lambda p: p.name,
    )
    if not versions:
        print(f"❌ Error: no version folder (vX.X.X) found in {sdlc_dir}.")
        return 1

    current_v = versions[-1]
    print(f"--- AQ SDLC — Version: {current_v.name} ---")
    errors: list[str] = []

    config = load_config(project_root)
    validate_config_schema(config, errors)

    contents = {prefix: read_text(current_v / fname) for prefix, fname in CHAIN_FILES.items()}
    ids = {prefix: extract_ids(content, prefix) for prefix, content in contents.items()}

    if not ids["E"]:
        errors.append("1_elicitation.md is empty or has no E### identifier.")

    a_links = extract_parent_links(contents["A"], "A")
    if ids["A"]:
        orphan = [aid for aid, pid in a_links.items() if pid not in ids["E"]]
        if orphan:
            errors.append(f"Orphan A### (parent E### does not exist): {orphan}")
        unlinked = [aid for aid in ids["A"] if aid not in a_links]
        if unlinked:
            errors.append(f"A### without a declared ID:PARENT link: {unlinked}")
    elif ids["E"]:
        errors.append("No A### in 2_architecture.md although E### exist.")

    p_links = extract_parent_links(contents["P"], "P")
    if ids["P"]:
        orphan = [pid for pid, aid in p_links.items() if aid not in ids["A"]]
        if orphan:
            errors.append(f"Orphan P### (parent A### does not exist): {orphan}")
        unlinked = [pid for pid in ids["P"] if pid not in p_links]
        if unlinked:
            errors.append(f"P### without a declared ID:PARENT link: {unlinked}")
    elif ids["A"]:
        errors.append("No P### in 3_conception.md although A### exist.")

    t_links = extract_parent_links(contents["T"], "T")
    if ids["T"]:
        orphan = [tid for tid, pid in t_links.items() if pid not in ids["P"]]
        if orphan:
            errors.append(f"Orphan T### (parent P### does not exist): {orphan}")
        unlinked = [tid for tid in ids["T"] if tid not in t_links]
        if unlinked:
            errors.append(f"T### without a declared ID:PARENT link: {unlinked}")
    elif ids["P"]:
        errors.append("No T### in 4_tests.md although P### exist.")

    waves = validate_waves(contents["P"], ids["P"], errors)
    detect_dag_cycles(contents["P"], waves, errors)

    all_ids: list[str] = []
    for pid_set in ids.values():
        all_ids.extend(pid_set)
    duplicates = sorted({i for i in all_ids if all_ids.count(i) > 1})
    if duplicates:
        errors.append(f"Duplicate identifiers: {duplicates}")

    for prefix, fname in CHAIN_FILES.items():
        if "🚫" in contents[prefix] or "[B]" in contents[prefix]:
            errors.append(f"Active blocker detected in {fname} (🚫 or [B]).")

    asvs_level = int(config.get("asvs_level", 1)) if config else 0
    run_asvs_scan(project_root, asvs_level, errors)

    print()
    if errors:
        for err in errors:
            print(f"❌ {err}")
        print(f"\n🚫 AQ FAIL — {len(errors)} error(s). Fix them before continuing.")
        return 1
    print(f"✅ AQ PASS — {current_v.name} validated. Ready for the next step.")
    return 0


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "SDLC AQ Gate — validates the E→A→P→T chain, the sdlc-config.json schema "
            "and the waves, and runs the ASVS scan when asvs_level >= 1."
        ),
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=None,
        help="Root of the project to validate (must contain SDLC_PM/). Default: current directory.",
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    args = _parse_args()
    sys.exit(check_traceability(project_root=args.project_root))
