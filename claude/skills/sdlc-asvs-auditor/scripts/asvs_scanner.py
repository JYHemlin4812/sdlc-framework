"""asvs_scanner.py — OWASP ASVS scanner for SDLC.

Scans a project's source code for ASVS anti-patterns at the configured level
(L1/L2/L3). Per-level patterns are stored as JSON in the sibling file
`asvs_patterns.json`.

Levels:
  L1 — Basic: plaintext secrets, weak hashes, eval/exec, SQL string concatenation
  L2 — Recommended: L1 + overly broad permissions, HTTP without TLS, CSRF, disabled TLS verification
  L3 — High security: L2 + custom crypto, unsafe deserialization, shell execution

Exit codes:
  - 0: no high-severity finding
  - 1: high-severity findings detected
  - 2: scan error

Usage:
  python asvs_scanner.py --level 2 --root .
  python asvs_scanner.py --level 1 --root ./api/auth --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


PATTERNS_FILE = Path(__file__).parent / "asvs_patterns.json"

# Default patterns (used when asvs_patterns.json is missing or invalid).
DEFAULT_PATTERNS = {
    "L1": [
        {"id": "ASVS-1.1", "name": "Hardcoded password",
         "regex": r"(?i)(password|passwd|pwd)\s*=\s*['\"][^'\"]{4,}['\"]",
         "severity": "high",
         "extensions": [".py", ".js", ".ts", ".go", ".rs", ".env", ".yml", ".yaml"]},
        {"id": "ASVS-1.2", "name": "API key in source",
         "regex": r"(?i)(api[_-]?key|secret|token)\s*=\s*['\"][A-Za-z0-9_\-]{16,}['\"]",
         "severity": "high",
         "extensions": [".py", ".js", ".ts", ".go", ".rs", ".env"]},
        {"id": "ASVS-1.3", "name": "Weak hash MD5/SHA1",
         "regex": r"\b(md5|sha1)\s*\(",
         "severity": "high",
         "extensions": [".py", ".js", ".ts", ".go", ".rs"]},
        {"id": "ASVS-1.4", "name": "Use of eval/exec",
         "regex": r"\b(eval|exec)\s*\(",
         "severity": "high",
         "extensions": [".py", ".js", ".ts"]},
        {"id": "ASVS-1.5", "name": "SQL string concatenation",
         "regex": r"(SELECT|INSERT|UPDATE|DELETE)\s.*['\"]?\s*\+\s*[a-zA-Z_]",
         "severity": "high",
         "extensions": [".py", ".js", ".ts", ".go", ".rs"]},
    ],
    "L2": [
        {"id": "ASVS-2.1", "name": "World-writable permission (chmod 777)",
         "regex": r"chmod\s+(0o)?777\b",
         "severity": "medium",
         "extensions": [".py", ".sh", ".ps1"]},
        {"id": "ASVS-2.2", "name": "HTTP without TLS",
         "regex": r"http://(?!localhost|127\.0\.0\.1)",
         "severity": "medium",
         "extensions": [".py", ".js", ".ts", ".go", ".rs", ".yml", ".yaml", ".json"]},
        {"id": "ASVS-2.3", "name": "Missing CSRF token",
         "regex": r"@app\.route.*methods=\[.*POST.*\](?!.*csrf)",
         "severity": "medium",
         "extensions": [".py"]},
    ],
    "L3": [
        {"id": "ASVS-3.1", "name": "Custom crypto (AES manual)",
         "regex": r"AES\.new\([^)]*MODE_ECB",
         "severity": "high",
         "extensions": [".py"]},
        {"id": "ASVS-3.2", "name": "Unsafe deserialization (pickle)",
         "regex": r"pickle\.load[s]?\s*\(",
         "severity": "high",
         "extensions": [".py"]},
        {"id": "ASVS-3.3", "name": "Subprocess shell=True with user input",
         "regex": r"subprocess\.(?:Popen|run|call)\s*\([^)]*shell\s*=\s*True",
         "severity": "high",
         "extensions": [".py"]},
    ],
}


@dataclass
class Finding:
    pattern_id: str
    name: str
    severity: str
    file: str
    line: int
    snippet: str


@dataclass
class ScanResult:
    level: int
    root: str
    files_scanned: int
    findings: list[Finding] = field(default_factory=list)


def load_patterns(level: int) -> list[dict]:
    """Return the patterns accumulated up to the requested level (L1 ⊆ L2 ⊆ L3)."""
    if PATTERNS_FILE.exists():
        try:
            data = json.loads(PATTERNS_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = DEFAULT_PATTERNS
    else:
        data = DEFAULT_PATTERNS
    patterns: list[dict] = []
    for tier in range(1, level + 1):
        patterns.extend(data.get(f"L{tier}", []))
    return patterns


SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", "_archive", "dist", "build", "target",
    ".venv", "venv",
    # coverage HTML reports contain regex.exec() wrongly flagged as eval/exec  (asvs-ignore: self-reference, this comment documents the scanner's false positive on itself)
    "htmlcov", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".coverage",
    # Misc generated / third-party
    ".idea", ".vscode", "site-packages", "egg-info",
}


def iter_source_files(root: Path, allowed_ext: set[str]):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.suffix.lower() not in allowed_ext:
            continue
        yield path


def scan(root: Path, level: int) -> ScanResult:
    patterns = load_patterns(level)
    compiled = [(p, re.compile(p["regex"])) for p in patterns]
    allowed_ext = {ext for p in patterns for ext in p.get("extensions", [])}
    result = ScanResult(level=level, root=str(root), files_scanned=0)
    for path in iter_source_files(root, allowed_ext):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        result.files_scanned += 1
        for pat, regex in compiled:
            if path.suffix.lower() not in pat.get("extensions", []):
                continue
            for match in regex.finditer(text):
                line_no = text.count("\n", 0, match.start()) + 1
                snippet = text.splitlines()[line_no - 1] if line_no - 1 < len(text.splitlines()) else ""
                # Explicit inline suppression (like `# nosec` / `# noqa`): a line carrying the
                # `asvs-ignore` marker is dropped from the report. The scanner stays conservative
                # (it flags matches even in comments); the suppression stays auditable because it
                # is visible and justified in the source — never a silent global skip.
                if "asvs-ignore" in snippet:
                    continue
                result.findings.append(
                    Finding(
                        pattern_id=pat["id"],
                        name=pat["name"],
                        severity=pat["severity"],
                        file=str(path.relative_to(root)),
                        line=line_no,
                        snippet=snippet.strip()[:120],
                    )
                )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="OWASP ASVS scanner for SDLC")
    parser.add_argument("--level", type=int, choices=[1, 2, 3], default=1)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    if not args.root.exists():
        print(f"❌ Root not found: {args.root}", file=sys.stderr)
        return 2

    result = scan(args.root, args.level)
    high_findings = [f for f in result.findings if f.severity == "high"]

    if args.json:
        payload = asdict(result)
        payload["findings"] = [asdict(f) for f in result.findings]
        payload["high_severity_count"] = len(high_findings)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(f"--- ASVS L{args.level} scan — root: {args.root} ---")
        print(f"Files scanned: {result.files_scanned}")
        print(f"Total findings: {len(result.findings)} (high severity: {len(high_findings)})")
        for f in result.findings:
            print(f"[{f.severity.upper()}] {f.pattern_id} {f.name} — {f.file}:{f.line}")
            if f.snippet:
                print(f"    > {f.snippet}")

    return 1 if high_findings else 0


if __name__ == "__main__":
    sys.exit(main())
