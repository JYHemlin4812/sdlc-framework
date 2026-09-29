"""Unit tests for wave_planner.py.

The parsing tests exist in two flavors: English field markers (`**Depends on**`,
`**Target files**`) and the legacy French markers (`**Dépend de**`,
`**Fichiers cibles**`), which stay supported for older design files.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import wave_planner  # noqa: E402


def test_kahn_linear_chain():
    """P1 → P2 → P3 yields 3 waves of one task each."""
    deps = {"P001": set(), "P002": {"P001"}, "P003": {"P002"}}
    waves, cycles = wave_planner.kahn_layers(deps)
    assert waves == [["P001"], ["P002"], ["P003"]]
    assert cycles == []


def test_kahn_independent_tasks():
    """3 tasks without dependencies → 1 wave of 3 tasks."""
    deps = {"P001": set(), "P002": set(), "P003": set()}
    waves, cycles = wave_planner.kahn_layers(deps)
    assert waves == [["P001", "P002", "P003"]]
    assert cycles == []


def test_kahn_diamond():
    """Diamond pattern: P1 ┬─ P2 ─┬ P4 ; P1 ─ P3 ─┘"""
    deps = {
        "P001": set(),
        "P002": {"P001"},
        "P003": {"P001"},
        "P004": {"P002", "P003"},
    }
    waves, cycles = wave_planner.kahn_layers(deps)
    assert waves == [["P001"], ["P002", "P003"], ["P004"]]
    assert cycles == []


def test_kahn_cycle():
    """Cycle P1 → P2 → P1 must be detected."""
    deps = {"P001": {"P002"}, "P002": {"P001"}}
    waves, cycles = wave_planner.kahn_layers(deps)
    assert "P001" in cycles
    assert "P002" in cycles


# --- parse_dag: English markers ---


def test_parse_dag_english_markers():
    """`**Depends on**` with `none`, a single parent and a list of parents."""
    content = """
#### P001 — foo
- **Depends on**: none

#### P002 — bar
- **Depends on**: P001

#### P003 — baz
- **Depends on** : P001, P002
"""
    deps = wave_planner.parse_dag(content)
    assert deps == {"P001": set(), "P002": {"P001"}, "P003": {"P001", "P002"}}


def test_parse_dag_english_dash():
    """`**Depends on**: —` means no dependency."""
    content = """
#### P001 — foo
- **Depends on**: —

#### P002 — bar
- **Depends on**: P001
"""
    deps = wave_planner.parse_dag(content)
    assert deps == {"P001": set(), "P002": {"P001"}}


# --- parse_dag: legacy French markers ---


def test_parse_dag_with_aucune():
    """Legacy `**Dépend de**` marker with `aucune`."""
    content = """
#### P001 — foo
- **Dépend de** : aucune

#### P002 — bar
- **Dépend de** : P001

#### P003 — baz
- **Dépend de** : P001, P002
"""
    deps = wave_planner.parse_dag(content)
    assert deps == {"P001": set(), "P002": {"P001"}, "P003": {"P001", "P002"}}


def test_parse_dag_dash():
    """Legacy `**Dépend de**` marker with a dash."""
    content = """
#### P001 — foo
- **Dépend de** : —

#### P002 — bar
- **Dépend de** : P001
"""
    deps = wave_planner.parse_dag(content)
    assert deps == {"P001": set(), "P002": {"P001"}}


def test_parse_dag_self_dependency_ignored():
    """A task depending on itself is ignored."""
    content = """
#### P001 — foo
- **Dépend de** : P001

#### P002 — bar
- **Depends on**: P002
"""
    deps = wave_planner.parse_dag(content)
    assert deps == {"P001": set(), "P002": set()}


def test_annotate_file_updates_waves(tmp_path: Path):
    """--annotate rewrites stale `wave` values."""
    src = """# Design

#### P001 — alpha
- **wave** : 99
- **Depends on**: none

#### P002 — beta
- **wave** : 99
- **Depends on**: P001
"""
    f = tmp_path / "3_conception.md"
    f.write_text(src, encoding="utf-8")
    deps = wave_planner.parse_dag(f.read_text(encoding="utf-8"))
    waves, cycles = wave_planner.kahn_layers(deps)
    assert cycles == []
    wave_planner.annotate_file(f, waves)
    updated = f.read_text(encoding="utf-8")
    assert "**wave** : 1" in updated
    assert "**wave** : 2" in updated
    assert "**wave** : 99" not in updated


# --- Bernstein linter (write-sets / intra-wave write conflicts) ---


def test_parse_write_sets_english_markers():
    """`**Target files**`: comma-separated paths, separators normalized."""
    content = """
#### P001 — foo
- **Target files**: src/app.py, src\\util.py

#### P002 — bar
- **Target files**: `docs/readme.md`
"""
    ws = wave_planner.parse_write_sets(content)
    assert ws == {
        "P001": {"src/app.py", "src/util.py"},
        "P002": {"docs/readme.md"},
    }


def test_parse_write_sets_english_ignores_placeholder():
    """English placeholder, `none` and a missing field → empty set (silent)."""
    content = """
#### P001 — foo
- **Target files**: `<relative paths>`

#### P002 — bar
- **Target files**: none

#### P003 — baz
- **Depends on**: none
"""
    ws = wave_planner.parse_write_sets(content)
    assert ws == {"P001": set(), "P002": set(), "P003": set()}


def test_parse_write_sets_basic():
    """Legacy `**Fichiers cibles**` marker: comma-separated paths, separators normalized."""
    content = """
#### P001 — foo
- **Fichiers cibles** : src/app.py, src\\util.py

#### P002 — bar
- **Fichiers cibles** : `docs/readme.md`
"""
    ws = wave_planner.parse_write_sets(content)
    assert ws == {
        "P001": {"src/app.py", "src/util.py"},
        "P002": {"docs/readme.md"},
    }


def test_parse_write_sets_ignores_placeholder():
    """Legacy marker: placeholder `<...>`, empty values and a missing field → empty set."""
    content = """
#### P001 — foo
- **Fichiers cibles** : `<chemins relatifs>`

#### P002 — bar
- **Fichiers cibles** : aucune

#### P003 — baz
- **Dépend de** : aucune
"""
    ws = wave_planner.parse_write_sets(content)
    assert ws == {"P001": set(), "P002": set(), "P003": set()}


def test_detect_conflict_same_file_same_wave():
    """Two P### of the same wave writing the same file → 1 conflict."""
    waves = [["P001", "P002"]]
    write_sets = {"P001": {"src/app.py"}, "P002": {"src/app.py"}}
    conflicts = wave_planner.detect_write_conflicts(waves, write_sets)
    assert conflicts == [
        {"wave": 1, "tasks": ["P001", "P002"], "files": ["src/app.py"]}
    ]


def test_detect_no_conflict_different_files():
    """Different files in the same wave → no conflict."""
    waves = [["P001", "P002"]]
    write_sets = {"P001": {"src/a.py"}, "P002": {"src/b.py"}}
    assert wave_planner.detect_write_conflicts(waves, write_sets) == []


def test_detect_no_conflict_across_waves():
    """Same file but different waves → no conflict (the DAG orders them)."""
    waves = [["P001"], ["P002"]]
    write_sets = {"P001": {"src/app.py"}, "P002": {"src/app.py"}}
    assert wave_planner.detect_write_conflicts(waves, write_sets) == []
