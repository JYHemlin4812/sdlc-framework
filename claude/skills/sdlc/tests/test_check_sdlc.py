"""Unit tests for check_sdlc.py (SDLC AQ validator)."""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pytest

# Add the scripts/ directory to the import path
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import check_sdlc  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"

LEGACY_FRENCH_CONCEPTION = """# 3 — Conception

#### P001:A001 — Fonction parse_csv
- **wave** : 1
- **Couvre A###** : A001
- **Dépend de** : aucune
- **Fichiers cibles** : `src/parse.py`

#### P002:A002 — Fonction sum_total
- **wave** : 2
- **Couvre A###** : A002
- **Dépend de** : P001
- **Fichiers cibles** : `src/total.py`

| ID | Titre | Wave | Parent | Statut |
|---|---|---|---|---|
| P001 | parse_csv | 1 | A001 | ⬜ |
| P002 | sum_total | 2 | A002 | ⬜ |
"""


def test_pass_project(monkeypatch, capsys):
    """pass_project (English markers, config version 3.0) validates (exit 0)."""
    project = FIXTURES / "pass_project"
    code = check_sdlc.check_traceability(project)
    captured = capsys.readouterr()
    assert code == 0, f"Expected PASS, got FAIL:\n{captured.out}"
    assert "AQ PASS" in captured.out


def test_legacy_french_conception_still_validates(tmp_path, capsys):
    """A legacy 3_conception.md with French markers (`**Dépend de**`) still passes."""
    project = tmp_path / "legacy"
    shutil.copytree(FIXTURES / "pass_project", project)
    (project / "SDLC_PM" / "v1.0.0" / "3_conception.md").write_text(
        LEGACY_FRENCH_CONCEPTION, encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project)
    captured = capsys.readouterr()
    assert code == 0, f"Expected PASS, got FAIL:\n{captured.out}"
    assert "AQ PASS" in captured.out


@pytest.mark.parametrize("marker", ["**Depends on**", "**Dépend de**"])
def test_depends_on_marker_is_parsed(marker):
    """Both the English and the legacy French dependency markers feed the wave check."""
    content = f"""
#### P001:A001 — foo
- **wave** : 1
- {marker} : none

#### P002:A001 — bar
- **wave** : 1
- {marker} : P001
"""
    errors: list[str] = []
    check_sdlc.detect_dag_cycles(content, check_sdlc.extract_waves(content), errors)
    assert any("strictly earlier wave" in e for e in errors), errors


def test_fail_orphan_project(capsys):
    """fail_orphan has A001:E999 whose parent E999 does not exist -> exit 1."""
    project = FIXTURES / "fail_orphan"
    code = check_sdlc.check_traceability(project)
    captured = capsys.readouterr()
    assert code == 1
    assert "Orphan A###" in captured.out


def test_missing_sdlc_dir(capsys, tmp_path):
    """Exit 1 when SDLC_PM/ is missing."""
    code = check_sdlc.check_traceability(tmp_path)
    captured = capsys.readouterr()
    assert code == 1
    assert "not found" in captured.out


def test_extract_ids():
    content = "Here are E001, A002:E001 and P003:A002. Also T004:P003."
    e_ids = check_sdlc.extract_ids(content, "E")
    a_ids = check_sdlc.extract_ids(content, "A")
    p_ids = check_sdlc.extract_ids(content, "P")
    t_ids = check_sdlc.extract_ids(content, "T")
    assert e_ids == {"E001"}
    assert a_ids == {"A002"}
    assert p_ids == {"P003"}
    assert t_ids == {"T004"}


def test_extract_parent_links():
    content = "A002:E001 then A003:E001 and P004:A003."
    a_links = check_sdlc.extract_parent_links(content, "A")
    p_links = check_sdlc.extract_parent_links(content, "P")
    assert a_links == {"A002": "E001", "A003": "E001"}
    assert p_links == {"P004": "A003"}


def test_extract_waves_table():
    content = """
| ID | Title | Wave | Parent | Status |
|---|---|---|---|---|
| P001 | foo | 1 | A001 | ⬜ |
| P002 | bar | 2 | A002 | ⬜ |
"""
    waves = check_sdlc.extract_waves(content)
    assert waves == {"P001": 1, "P002": 2}


def test_extract_waves_section():
    content = """
#### P001 — foo
- **wave** : 3
- desc

#### P002 — bar
- **wave** : 5
"""
    waves = check_sdlc.extract_waves(content)
    assert waves["P001"] == 3
    assert waves["P002"] == 5


def test_validate_config_schema_ok():
    config = {"version": "3.0", "model_profile": "balanced", "asvs_level": 1, "primary_language": "python"}
    errors: list[str] = []
    check_sdlc.validate_config_schema(config, errors)
    assert errors == []


def test_validate_config_schema_v4_with_output_language_ok():
    config = {"version": "4.0", "model_profile": "balanced", "output_language": "fr"}
    errors: list[str] = []
    check_sdlc.validate_config_schema(config, errors)
    assert errors == []


@pytest.mark.parametrize("value", ["", "   ", 42])
def test_validate_config_schema_bad_output_language(value):
    config = {"version": "4.0", "output_language": value}
    errors: list[str] = []
    check_sdlc.validate_config_schema(config, errors)
    assert any("output_language" in e for e in errors), errors


def test_validate_config_schema_bad_version():
    config = {"version": "2.0"}
    errors: list[str] = []
    check_sdlc.validate_config_schema(config, errors)
    assert any("version" in e for e in errors)


def test_validate_config_schema_bad_profile():
    config = {"version": "3.0", "model_profile": "warp-speed"}
    errors: list[str] = []
    check_sdlc.validate_config_schema(config, errors)
    assert any("model_profile" in e for e in errors)
