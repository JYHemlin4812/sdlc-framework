"""stow_decay.py — Decay bookkeeping for SDLC_PM/STOW.md.

STOW.md holds one-line entries carrying a tier marker (concept adapted from the
`stow` skill of kunchenguid/firstmate, MIT):

  <!--a:YYYY-MM-DD-->  aging       last reinforced on that date; stale at 30 days
  <!--p:YYYY-MM-DD-->  perishable  last reinforced on that date; stale at 7 days
  <!--P-->             pinned      never decays
  (no marker)          unmarked    reported so the next sweep can stamp it

Subcommands (JSON on stdout):
  stale    List stale and unmarked entries with their line numbers.
  archive  Move entries (by line number) to `.stow-archive.md` next to the file,
           with provenance and a reason, and add that archive to a .gitignore in
           the same folder. Refuses when the archive file is tracked by git.

An entry is a markdown list line (`- ...` or `* ...`). Deciding whether a stale
entry is re-validated (date refreshed) or archived is a judgment call left to
the sweep; this script only finds the stale ones and does the archiving.

Exit codes:
  0 — Success
  2 — Input error (file not found, line is not an entry, archive tracked by git)

Usage:
  python stow_decay.py stale SDLC_PM/STOW.md [--today YYYY-MM-DD]
  python stow_decay.py archive SDLC_PM/STOW.md --line 12 --line 15 --reason "resolved"
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

ENTRY_RE = re.compile(r"^\s*[-*]\s+\S")
MARKER_RE = re.compile(r"\s*<!--\s*(?:([ap]):(\d{4}-\d{2}-\d{2})|(P))\s*-->\s*$")
HORIZON_DAYS = {"a": 30, "p": 7}
TIER_NAMES = {"a": "aging", "p": "perishable", "P": "pinned"}
ARCHIVE_NAME = ".stow-archive.md"


class InputError(Exception):
    """Bad input (exit code 2)."""


def parse_entries(lines: list[str], today: date) -> list[dict]:
    entries = []
    for number, line in enumerate(lines, start=1):
        if not ENTRY_RE.match(line):
            continue
        match = MARKER_RE.search(line)
        entry = {"line": number, "tier": "unmarked", "date": None, "age_days": None, "stale": False}
        if match:
            letter = match.group(1) or match.group(3)
            entry["tier"] = TIER_NAMES[letter]
            if match.group(2):
                entry["date"] = match.group(2)
                entry["age_days"] = (today - date.fromisoformat(match.group(2))).days
                entry["stale"] = entry["age_days"] >= HORIZON_DAYS[letter]
        entry["text"] = MARKER_RE.sub("", line).strip()
        entries.append(entry)
    return entries


def parse_today(value: str | None) -> date:
    try:
        return date.fromisoformat(value) if value else date.today()
    except ValueError as exc:
        raise InputError(f"invalid --today: {exc}") from exc


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        raise InputError(f"file not found: {path}")
    return path.read_text(encoding="utf-8").splitlines()


def cmd_stale(args: argparse.Namespace) -> dict:
    entries = parse_entries(read_lines(Path(args.file)), parse_today(args.today))
    return {
        "file": args.file,
        "stale": [e for e in entries if e["stale"]],
        "unmarked": [e for e in entries if e["tier"] == "unmarked"],
        "entries": len(entries),
    }


def is_tracked(path: Path) -> bool:
    proc = subprocess.run(
        ["git", "-C", str(path.parent), "ls-files", "--error-unmatch", path.name],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def ensure_ignored(directory: Path) -> None:
    ignore = directory / ".gitignore"
    current = ignore.read_text(encoding="utf-8") if ignore.exists() else ""
    if ARCHIVE_NAME not in current.splitlines():
        sep = "" if not current or current.endswith("\n") else "\n"
        ignore.write_text(current + sep + ARCHIVE_NAME + "\n", encoding="utf-8")


def cmd_archive(args: argparse.Namespace) -> dict:
    path = Path(args.file)
    lines = read_lines(path)
    today = parse_today(args.today)
    by_line = {e["line"]: e for e in parse_entries(lines, today)}
    wanted = sorted(set(args.line))
    missing = [n for n in wanted if n not in by_line]
    if missing:
        raise InputError(f"not an entry line: {missing}")
    archive = path.parent / ARCHIVE_NAME
    if archive.exists() and is_tracked(archive):
        raise InputError(f"{archive} is tracked by git: choose another destination first")
    records = []
    for n in wanted:
        e = by_line[n]
        last = f" last={e['date']}" if e["date"] else ""
        records.append(
            f"{e['text']} <!-- archived {today.isoformat()} from {path.name}"
            f" tier={e['tier']}{last}: {args.reason} -->"
        )
    previous = archive.read_text(encoding="utf-8") if archive.exists() else ""
    sep = "" if not previous or previous.endswith("\n") else "\n"
    archive.write_text(previous + sep + "\n".join(records) + "\n", encoding="utf-8")
    ensure_ignored(path.parent)
    keep = [line for i, line in enumerate(lines, start=1) if i not in set(wanted)]
    path.write_text("\n".join(keep) + "\n", encoding="utf-8")
    return {"file": args.file, "archived": wanted, "archive": str(archive)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Decay bookkeeping for SDLC_PM/STOW.md.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("stale", help="list stale and unmarked entries")
    p.add_argument("file", help="Path to STOW.md")
    p.add_argument("--today", help="Override today's date (YYYY-MM-DD)")
    p.set_defaults(func=cmd_stale)

    p = sub.add_parser("archive", help="move entries to .stow-archive.md")
    p.add_argument("file", help="Path to STOW.md")
    p.add_argument("--line", type=int, action="append", required=True, help="Entry line number (repeatable)")
    p.add_argument("--reason", required=True, help="One-line reason recorded in the archive")
    p.add_argument("--today", help="Override today's date (YYYY-MM-DD)")
    p.set_defaults(func=cmd_archive)

    args = parser.parse_args()
    try:
        result = args.func(args)
    except InputError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
