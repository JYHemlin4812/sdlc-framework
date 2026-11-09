"""check_sdlc.py — SDLC AQ validator (tier-aware, placeholder-aware).

Checks depend on `documentation_tier` in SDLC_PM/sdlc-config.json:

  - none       : nothing is checked; reports SKIPPED (exit 0), never PASS
  - minimal    : HANDOFF.md and RESUME.md must exist and be filled; HANDOFF older
                 than 7 days is a warning
  - standard   : the minimal checks, plus E→P (A### and T### optional)
  - full       : the minimal checks, plus strict E→A→P→T, and asvs_level >= 1
  - exhaustive : as full, and asvs_level >= 2
  - absent / legacy (no tier) : strict E→A→P→T, as in earlier versions

At every tier except none and legacy, unfilled template placeholders are errors.
Test coverage is not measured by this gate.

Field markers are accepted in English (`**Depends on**`) and in the legacy
French form (`**Dépend de**`) so older projects keep validating.

Exit codes:
  0 — PASS (or SKIPPED for tier none)
  1 — FAIL (traceability, schema, wave, placeholder or ASVS errors)
  2 — ERROR (invalid config JSON)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import date
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

SEMVER_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SUPPORTED_DOCUMENTATION_TIERS_SET = {"none", "minimal", "standard", "full", "exhaustive"}
TIERS_WITH_HANDOFF = {"minimal", "standard", "full", "exhaustive"}
TIERS_WITH_CHAIN = {"standard", "full", "exhaustive"}
TIERS_STRICT = {"full", "exhaustive"}
HANDOFF_MAX_AGE_DAYS = 7

# Fenced code blocks (``` or ~~~) are examples, not content.
CODE_FENCE = re.compile(
    # An unclosed fence runs to the end of the file, as in GFM (AQG-002).
    r"^[ \t]{0,3}(`{3,}|~{3,})([^\n]*)\n(.*?)(?:^[ \t]{0,3}\1[`~]*[ \t]*$|\Z)",
    re.DOTALL | re.MULTILINE,
)
# Command blocks in RESUME/HANDOFF hold required bootstrap steps (R02): they are checked.
COMMAND_LANGUAGES = {"bash", "sh", "shell", "zsh", "console", "powershell", "pwsh", "cmd", "bat"}


def strip_fences(text: str, *, keep_commands: bool = False) -> str:
    """Remove code blocks, except command blocks when keep_commands is set (their content stays)."""
    def replace(match: re.Match[str]) -> str:
        info = match.group(2).strip().split()
        language = info[0].lower() if info else ""
        # An unlabelled block in RESUME/HANDOFF is a bootstrap block too (inspection 7, 61.2).
        if keep_commands and (language in COMMAND_LANGUAGES or language == ""):
            return match.group(3)
        return ""
    return CODE_FENCE.sub(replace, text)
ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
PHASES = ("plan", "release")
LAST_UPDATED = re.compile(r"\*\*Last updated\*\*\s*:\s*([^\n]*)")
ISO_DATE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")


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


def select_version_dir(sdlc_dir: Path) -> Path | None:
    """Return the highest vX.Y.Z folder (numeric order). Other names are ignored."""
    candidates: list[tuple[tuple[int, int, int], Path]] = []
    for d in sdlc_dir.iterdir():
        match = SEMVER_PATTERN.match(d.name) if d.is_dir() else None
        if match:
            candidates.append((tuple(int(g) for g in match.groups()), d))  # type: ignore[arg-type]
    if not candidates:
        return None
    return max(candidates, key=lambda item: item[0])[1]


_TEMPLATE_LINES: dict[bool, set[str]] = {}


def template_placeholder_lines(keep_fences: bool = False) -> set[str]:
    """Lines of the shipped templates that still carry a `<...>` placeholder (cached).

    A document line is an unfilled placeholder when it is identical to one of these lines.
    Comparing with the shipped templates catches prose, table cells and multi-line criteria,
    and does not flag legitimate values such as `<dialog>` (D-B, option b).
    With keep_fences, lines inside code blocks are included (required bootstrap commands, R02).
    """
    if keep_fences not in _TEMPLATE_LINES:
        lines: set[str] = set()
        for template in ASSETS_DIR.glob("*.template.md"):
            body = strip_fences(template.read_text(encoding="utf-8"), keep_commands=keep_fences)
            span: list[str] = []  # a placeholder that opens on one line and closes on a later one
            for line in body.splitlines():
                stripped = line.strip()
                if span:
                    span.append(stripped)
                    if stripped.endswith(">`") or stripped.endswith(">"):
                        lines.update(span)
                        span = []
                    continue
                if "<" in stripped and ">" in stripped:
                    lines.add(stripped)
                elif stripped.startswith("`<"):
                    span = [stripped]
        lines.discard("")
        _TEMPLATE_LINES[keep_fences] = lines
    return _TEMPLATE_LINES[keep_fences]


def unfilled_placeholders(text: str, *, keep_fences: bool = False) -> list[str]:
    """Return the lines of a document that are still identical to a template placeholder line.

    Fenced code blocks are examples, not content: they are excluded (aq-gate.md).
    """
    body = strip_fences(text, keep_commands=keep_fences)
    known = template_placeholder_lines(keep_fences=keep_fences)
    return [line.strip() for line in body.splitlines() if line.strip() in known]


def check_handoff(sdlc_dir: Path, today: date, errors: list[str], warnings: list[str]) -> None:
    """HANDOFF.md and RESUME.md must exist and be filled; HANDOFF age is a warning (D3)."""
    handoff = sdlc_dir / "HANDOFF.md"
    resume = sdlc_dir / "RESUME.md"
    if not handoff.exists():
        errors.append("HANDOFF.md is missing (required from tier minimal).")
    if not resume.exists():
        errors.append("RESUME.md is missing (required from tier minimal).")
    if resume.exists():
        resume_text = resume.read_text(encoding="utf-8")
        if not resume_text.strip():
            errors.append("RESUME.md is empty: it must hold the technical bootstrap.")
        # Bootstrap commands sit in code blocks and are required, so fences are not exempt (R02).
        for hit in unfilled_placeholders(resume_text, keep_fences=True):
            errors.append(f"Unfilled template placeholder in RESUME.md: {hit}")
    if not handoff.exists():
        return
    text = handoff.read_text(encoding="utf-8")
    for hit in unfilled_placeholders(text, keep_fences=True):
        errors.append(f"Unfilled template placeholder in HANDOFF.md: {hit}")
    # The template placeholder line itself is caught above (template-line matching). Here only the
    # date is validated: an author may legitimately write `<email>` after it (inspection 4, R03).
    match = LAST_UPDATED.search(text)
    value = match.group(1) if match else ""
    date_match = ISO_DATE.search(value)
    if not date_match:
        errors.append("HANDOFF.md has no readable '**Last updated**' date (YYYY-MM-DD).")
        return
    try:
        updated = date(*(int(g) for g in date_match.groups()))
    except ValueError:
        errors.append(f"HANDOFF.md has an invalid '**Last updated**' date: {date_match.group(0)}.")
        return
    age = (today - updated).days
    if age > HANDOFF_MAX_AGE_DAYS:
        warnings.append(
            f"HANDOFF.md last updated {age} days ago (more than {HANDOFF_MAX_AGE_DAYS})."
        )


def _digest(text: str) -> str:
    """SHA-256 of the text, ignoring line-end whitespace and surrounding blank lines."""
    normalized = "\n".join(line.rstrip() for line in text.strip().splitlines())
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


# Optional skeletons shipped by earlier releases (digests of their normalized text). A project
# created before a template changed still holds the old skeleton, untouched: it was never
# authored (inspection 10, REV-001, option 70.1.1). Add the digest of a template here
# BEFORE changing it in assets/.
KNOWN_SHIPPED_SKELETONS: dict[str, set[str]] = {
    "2_architecture": {
        "cd778a69fec2ed93ceaaf0c3a0281e5112757ab1278689536728fb1c5faa9f28",  # release e28448a
    },
    "4_tests": {
        "070623a7351c4354357569b1155946af4faeac61c224ce13ecc27ded57b2cf11",  # release e28448a
    },
}


def _is_unauthored_skeleton(text: str, name: str) -> bool:
    """True when the document is the current or a previously shipped skeleton, unchanged."""
    template = ASSETS_DIR / f"{name}.template.md"
    known = set(KNOWN_SHIPPED_SKELETONS.get(name, set()))
    if template.exists():
        known.add(_digest(template.read_text(encoding="utf-8")))
    return _digest(text) in known


def check_chain(current_v: Path, tier: str | None, errors: list[str], phase: str = "release") -> None:
    """E→A→P→T checks. Legacy and full/exhaustive are strict; standard lets A### and T### be absent.

    At phase `plan` (precondition of /sdlc:dev), 4_tests.md is not required yet (D-A).
    """
    legacy = tier not in SUPPORTED_DOCUMENTATION_TIERS_SET
    standard = tier == "standard"
    strict = legacy or tier in TIERS_STRICT

    # At phase plan, 4_tests.md is written during development: it is not read at all (R01, R03).
    contents = {
        prefix: ("" if phase == "plan" and prefix == "T" else read_text(current_v / fname))
        for prefix, fname in CHAIN_FILES.items()
    }
    if standard:
        # deploy_init copies every template. At standard, an optional document still identical
        # to its shipped template was never authored, so it is treated as absent (R04).
        for prefix in ("A", "T"):
            name = CHAIN_FILES[prefix].removesuffix(".md")
            if contents[prefix] and _is_unauthored_skeleton(contents[prefix], name):
                contents[prefix] = ""
    if not legacy:
        # Identifiers and parent links inside code blocks are examples, not traceability (REV-001).
        # Legacy projects keep their historical extraction.
        contents = {prefix: strip_fences(content) for prefix, content in contents.items()}
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
    elif ids["E"] and strict:
        errors.append("No A### in 2_architecture.md although E### exist.")

    p_links = extract_parent_links(contents["P"], "P")
    if ids["P"]:
        # Standard: a P### may hang from an E### when no A### is written (D5).
        parents = ids["E"] if (standard and not ids["A"]) else ids["A"]
        orphan = [pid for pid, aid in p_links.items() if aid not in parents]
        if orphan:
            errors.append(f"Orphan P### (parent does not exist): {orphan}")
        unlinked = [pid for pid in ids["P"] if pid not in p_links]
        if unlinked:
            errors.append(f"P### without a declared ID:PARENT link: {unlinked}")
    elif ids["A"] or (standard and ids["E"]):
        # Standard still requires E→P: a missing P### is an error whatever A### holds (AQ-001).
        errors.append("No P### in 3_conception.md although A### or E### exist.")

    t_links = extract_parent_links(contents["T"], "T")
    if ids["T"]:
        orphan = [tid for tid, pid in t_links.items() if pid not in ids["P"]]
        if orphan:
            errors.append(f"Orphan T### (parent P### does not exist): {orphan}")
        unlinked = [tid for tid in ids["T"] if tid not in t_links]
        if unlinked:
            errors.append(f"T### without a declared ID:PARENT link: {unlinked}")
    elif ids["P"] and not standard and phase != "plan":
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

    if not legacy:
        for prefix, fname in CHAIN_FILES.items():
            for hit in unfilled_placeholders(contents[prefix]):
                errors.append(f"Unfilled template placeholder in {fname}: {hit}")


def check_traceability(
    project_root: Path | None = None, today: date | None = None, phase: str = "release"
) -> int:
    project_root = project_root or Path.cwd()
    today = today or date.today()
    if phase not in PHASES:
        raise ValueError(f"unknown phase {phase!r}, expected one of {PHASES}")
    sdlc_dir = project_root / "SDLC_PM"
    if not sdlc_dir.exists():
        print(f"❌ Error: folder {sdlc_dir} not found.")
        return 1

    errors: list[str] = []
    warnings: list[str] = []

    try:
        config = load_config(project_root)
    except SystemExit as exc:
        print(exc.code)
        return 2
    validate_config_schema(config, errors)

    tier = config.get("documentation_tier") if config else None
    if tier == "none":
        print("--- AQ SDLC — Tier: none ---")
        print("\n⏭ AQ SKIPPED — documentation_tier none: nothing is checked. This is not a PASS.")
        return 0

    legacy = tier not in SUPPORTED_DOCUMENTATION_TIERS_SET
    current_v = select_version_dir(sdlc_dir)
    needs_version = legacy or tier in TIERS_WITH_CHAIN
    if needs_version and current_v is None:
        print(f"❌ Error: no version folder (vX.X.X) found in {sdlc_dir}.")
        return 1

    label = current_v.name if current_v is not None else f"tier {tier}"
    print(f"--- AQ SDLC — Version: {label} ---" if current_v is not None else f"--- AQ SDLC — Tier: {tier} ---")

    if tier in TIERS_WITH_HANDOFF:
        check_handoff(sdlc_dir, today, errors, warnings)
    if needs_version and current_v is not None:
        check_chain(current_v, tier, errors, phase=phase)

    asvs_level = int(config.get("asvs_level", 1)) if config else 0
    if tier == "full" and asvs_level < 1:
        errors.append(f"documentation_tier full requires asvs_level >= 1 (found {asvs_level}).")
    if tier == "exhaustive" and asvs_level < 2:
        errors.append(f"documentation_tier exhaustive requires asvs_level >= 2 (found {asvs_level}).")
    run_asvs_scan(project_root, asvs_level, errors)

    print()
    for warning in warnings:
        print(f"⚠️ {warning}")
    if errors:
        for err in errors:
            print(f"❌ {err}")
        print(f"\n🚫 AQ FAIL — {len(errors)} error(s). Fix them before continuing.")
        return 1
    print(f"✅ AQ PASS — {label} validated. Ready for the next step.")
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
    parser.add_argument(
        "--today",
        type=date.fromisoformat,
        default=None,
        help="Reference date (YYYY-MM-DD) for the HANDOFF age check. Default: today. Used by tests.",
    )
    parser.add_argument(
        "--phase",
        choices=PHASES,
        default="release",
        help="plan: precondition of /sdlc:dev (4_tests.md not required yet). release: full check (default).",
    )
    return parser.parse_args(argv)


if __name__ == "__main__":
    args = _parse_args()
    sys.exit(check_traceability(project_root=args.project_root, today=args.today, phase=args.phase))
