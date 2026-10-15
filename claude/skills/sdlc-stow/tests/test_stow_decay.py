"""Unit tests for stow_decay.py."""

from __future__ import annotations

import sys
from argparse import Namespace
from datetime import date
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import stow_decay as sd  # noqa: E402

TODAY = date(2026, 10, 14)

STOW = """\
<!-- memory tiers: see the sdlc-stow skill -->
## Gotchas
- aging exactly at horizon <!--a:2026-09-14-->
- aging one day short <!--a:2026-09-15-->
- perishable at horizon, tracked in TODO <!--p:2026-10-07-->
- perishable one day short <!--p:2026-10-08-->
- pinned old fact <!--P-->
- legacy entry without marker
Not an entry line.
"""


def write(tmp_path: Path, text: str = STOW) -> Path:
    f = tmp_path / "STOW.md"
    f.write_text(text, encoding="utf-8")
    return f


def test_parse_tiers_and_horizons():
    entries = sd.parse_entries(STOW.splitlines(), TODAY)
    by_text = {e["text"]: e for e in entries}
    assert by_text["- aging exactly at horizon"]["stale"] is True
    assert by_text["- aging one day short"]["stale"] is False
    assert by_text["- perishable at horizon, tracked in TODO"]["stale"] is True
    assert by_text["- perishable one day short"]["stale"] is False
    assert by_text["- pinned old fact"]["tier"] == "pinned"
    assert by_text["- pinned old fact"]["stale"] is False
    assert by_text["- legacy entry without marker"]["tier"] == "unmarked"
    assert len(entries) == 6  # headings and prose are not entries


def test_stale_command(tmp_path: Path):
    out = sd.cmd_stale(Namespace(file=str(write(tmp_path)), today=TODAY.isoformat()))
    assert [e["line"] for e in out["stale"]] == [3, 5]
    assert [e["line"] for e in out["unmarked"]] == [8]


def test_archive_moves_entries_and_ignores_archive(tmp_path: Path):
    f = write(tmp_path)
    out = sd.cmd_archive(Namespace(file=str(f), line=[3, 5], reason="resolved", today=TODAY.isoformat()))
    assert out["archived"] == [3, 5]
    left = f.read_text(encoding="utf-8")
    assert "aging exactly at horizon" not in left and "perishable at horizon" not in left
    assert "pinned old fact" in left
    archive = (tmp_path / ".stow-archive.md").read_text(encoding="utf-8")
    assert "tier=aging last=2026-09-14: resolved" in archive
    assert "tier=perishable last=2026-10-07: resolved" in archive
    assert (tmp_path / ".gitignore").read_text(encoding="utf-8").splitlines() == [".stow-archive.md"]
    sd.cmd_archive(Namespace(file=str(f), line=[6], reason="again", today=TODAY.isoformat()))
    assert (tmp_path / ".gitignore").read_text(encoding="utf-8").count(".stow-archive.md") == 1


def test_archive_rejects_non_entry_line_without_writing(tmp_path: Path):
    f = write(tmp_path)
    with pytest.raises(sd.InputError):
        sd.cmd_archive(Namespace(file=str(f), line=[1], reason="x", today=TODAY.isoformat()))
    assert f.read_text(encoding="utf-8") == STOW
    assert not (tmp_path / ".stow-archive.md").exists()
