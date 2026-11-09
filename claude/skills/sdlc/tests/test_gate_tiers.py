"""Tests for the tier-aware AQ Gate (check_sdlc.py), plan fix/gate-tiers-placeholders.

Each test builds its project in tmp_path. Dates are computed relative to today,
so no clock injection is needed.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import check_sdlc  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
ASSETS = Path(__file__).resolve().parent.parent / "assets"
PS1 = SCRIPTS_DIR / "check_sdlc.ps1"


def _pwsh() -> str:
    """Path of a PowerShell executable, or '' when none is installed (wrapper tests are skipped)."""
    for name in ("pwsh", "powershell"):
        found = shutil.which(name)
        if found:
            return found
    return ""

FILLED_ELICITATION = """# 1 — Elicitation

## Requirements (E###)

#### E001 — Parse CSV files
- **Description** : Read a CSV file and return rows.
- **Acceptance criterion** : Given a valid CSV, when parsed, then rows are returned.
"""

FILLED_ARCHITECTURE = """# 2 — Architecture

### A001:E001 — Use the csv standard library
- **Context** : Parsing needs no third-party dependency.
- **Decision** : Use csv from the standard library.
- **Covers** : E001
"""

FILLED_CONCEPTION_WITH_A = """# 3 — Conception

#### P001:A001 — Implement parse_csv
- **wave** : 1
- **Description** : Implement the reader.
- **Depends on** : none
"""

FILLED_CONCEPTION_E_ONLY = """# 3 — Conception

#### P001:E001 — Implement parse_csv
- **wave** : 1
- **Description** : Implement the reader.
- **Depends on** : none
"""

FILLED_TESTS = """# 4 — Tests

### T001:P001 — parse_csv returns rows
- **Target** : P001
- **Type** : unit
"""


def _handoff(day: date) -> str:
    return (
        "# HANDOFF\n\n"
        f"- **Last updated** : {day.isoformat()} by tester\n\n"
        "## Next 3 actions\n1. Run the tests.\n"
    )


RESUME_FILLED = "# RESUME\n\n## Step-by-step setup\n1. Install the dependencies.\n"


def make_project(
    root: Path,
    tier: str | None,
    *,
    asvs: int = 0,
    chain: str = "strict",
    fill: bool = True,
    handoff_day: date | None = None,
    version: str = "v1.0.0",
) -> Path:
    """Create a project. chain: 'strict' (E,A,P,T), 'standard' (E,P), 'none' (no version folder)."""
    sdlc = root / "SDLC_PM"
    sdlc.mkdir(parents=True)
    config = {"version": "4.0", "asvs_level": asvs, "primary_language": "python"}
    if tier is not None:
        config["documentation_tier"] = tier
    (sdlc / "sdlc-config.json").write_text(json.dumps(config), encoding="utf-8")

    day = handoff_day or date.today()
    if tier in {"minimal", "standard", "full", "exhaustive"}:
        if fill:
            (sdlc / "HANDOFF.md").write_text(_handoff(day), encoding="utf-8")
            (sdlc / "RESUME.md").write_text(RESUME_FILLED, encoding="utf-8")
        else:
            shutil.copy(ASSETS / "HANDOFF.template.md", sdlc / "HANDOFF.md")
            shutil.copy(ASSETS / "RESUME.template.md", sdlc / "RESUME.md")

    if chain == "none":
        return root
    vdir = sdlc / version
    vdir.mkdir()
    if not fill:
        for src, dst in [
            ("1_elicitation.template.md", "1_elicitation.md"),
            ("2_architecture.template.md", "2_architecture.md"),
            ("3_conception.template.md", "3_conception.md"),
            ("4_tests.template.md", "4_tests.md"),
        ]:
            shutil.copy(ASSETS / src, vdir / dst)
        return root
    (vdir / "1_elicitation.md").write_text(FILLED_ELICITATION, encoding="utf-8")
    if chain == "strict":
        (vdir / "2_architecture.md").write_text(FILLED_ARCHITECTURE, encoding="utf-8")
        (vdir / "3_conception.md").write_text(FILLED_CONCEPTION_WITH_A, encoding="utf-8")
        (vdir / "4_tests.md").write_text(FILLED_TESTS, encoding="utf-8")
    else:  # standard: no architecture, no tests; P links to E
        (vdir / "3_conception.md").write_text(FILLED_CONCEPTION_E_ONLY, encoding="utf-8")
    return root


# --- 5.1 to 5.4: placeholders and the minimal tier -------------------------


def test_5_1_standard_with_untouched_templates_fails(tmp_path, capsys):
    """Reproduces 18.1: untouched templates must not pass at standard tier."""
    project = make_project(tmp_path / "p", "standard", fill=False, chain="strict")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out


def test_5_2_full_with_untouched_templates_fails(tmp_path, capsys):
    project = make_project(tmp_path / "p", "full", asvs=1, fill=False, chain="strict")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out


def test_5_3_minimal_with_filled_handoff_and_resume_passes(tmp_path, capsys):
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out
    assert "AQ PASS" in out


def test_5_4_minimal_with_template_handoff_fails(tmp_path, capsys):
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=False)
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out


# --- 5.5 to 5.6: standard tier chain and HANDOFF age -----------------------


def test_5_5_standard_without_architecture_passes(tmp_path, capsys):
    """Standard: E->P chain, A### and T### optional (D5)."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out
    assert "AQ PASS" in out


def test_5_6_stale_handoff_warns_without_failing(tmp_path, capsys):
    """D3: HANDOFF older than 7 days is a warning, exit stays 0."""
    project = make_project(
        tmp_path / "p",
        "standard",
        chain="standard",
        fill=True,
        handoff_day=FIXED_TODAY - timedelta(days=30),
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out
    warning_lines = [line for line in out.splitlines() if line.startswith("⚠️")]
    assert any("HANDOFF" in line for line in warning_lines), out


FIXED_TODAY = date(2026, 11, 20)


def test_5_20_plan_phase_ignores_unwritten_tests_document(tmp_path, capsys):
    """D-A: at `--phase plan` (precondition of /sdlc:dev) the gate does not require 4_tests.md."""
    project = make_project(tmp_path / "p", "full", asvs=1, chain="strict", fill=True)
    (project / "SDLC_PM" / "v1.0.0" / "4_tests.md").unlink()
    assert check_sdlc.check_traceability(project, phase="plan") == 0, capsys.readouterr().out
    assert check_sdlc.check_traceability(project) == 1, capsys.readouterr().out


def test_5_21_plan_phase_still_checks_the_other_documents(tmp_path, capsys):
    """D-A: `plan` only relaxes 4_tests.md; untouched architecture templates still fail."""
    project = make_project(tmp_path / "p", "full", asvs=1, chain="strict", fill=False)
    code = check_sdlc.check_traceability(project, phase="plan")
    out = capsys.readouterr().out
    assert code == 1, out
    assert "2_architecture.md" in out, out


def test_5_22_partially_filled_template_prose_is_detected(tmp_path, capsys):
    """D-B (R02): an untouched template criterion inside a filled document is a placeholder."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    (project / "SDLC_PM" / "v1.0.0" / "1_elicitation.md").write_text(
        FILLED_ELICITATION
        + "\n- **Acceptance criterion** :\n  > Given `<context>`, when `<action>`, then `<observable result>`.\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out


def test_5_23_legitimate_angle_bracket_value_is_not_a_placeholder(tmp_path, capsys):
    """D-B (R04): `<dialog>` in a field is content, not a template line."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n- **HTML element** : `<dialog>`\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_24_tilde_fenced_example_is_not_a_placeholder(tmp_path, capsys):
    """D-B (R05): ~~~ fences are code blocks, like ``` fences."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n~~~markdown\n- **Description** : `<T>`\n~~~\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_15_standard_without_any_p_fails(tmp_path, capsys):
    """Inspection AQ-001: E→P requires at least one P### at standard tier."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    (project / "SDLC_PM" / "v1.0.0" / "3_conception.md").write_text("# 3 — Conception\n", encoding="utf-8")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "P###" in out, out


def test_5_16_minimal_with_empty_resume_fails(tmp_path, capsys):
    """Inspection AQ-002: an empty RESUME.md is not a filled bootstrap."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text("   \n", encoding="utf-8")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "RESUME.md" in out, out


def test_5_17_fenced_placeholder_example_is_not_a_placeholder(tmp_path, capsys):
    """Inspection AQ-003: aq-gate.md exempts code blocks, at an active tier too."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n```markdown\n- **Description** : `<T>`\n```\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_18_wrapper_placeholder_echoing_skip_text_is_not_skipped(tmp_path):
    """Inspection AQ-004: an error line containing 'AQ SKIPPED' must not turn FAIL into SKIPPED."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    config = project / "SDLC_PM" / "sdlc-config.json"
    config.write_text(
        json.dumps({"version": "AQ SKIPPED", "asvs_level": 0, "documentation_tier": "standard"}),
        encoding="utf-8",
    )
    data = _run_wrapper(project)
    assert data["code"] == 1, data
    assert data["status"] == "FAIL", data
    assert any("AQ SKIPPED" in e for e in data["errors"]), data


def test_5_19_today_option_drives_the_handoff_age_warning(tmp_path):
    """Inspection AQ-006: --today reaches the age check (19 days here)."""
    project = make_project(
        tmp_path / "p", "minimal", chain="none", fill=True, handoff_day=date(2026, 11, 1)
    )
    result = subprocess.run(
        [sys.executable, str(SCRIPTS_DIR / "check_sdlc.py"), "--project-root", str(project),
         "--today", "2026-11-20"],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    assert result.returncode == 0, result.stdout
    assert "19 days" in result.stdout, result.stdout


# --- 5.7 to 5.8: version selection and config errors -----------------------


def test_5_7_highest_semantic_version_is_checked(tmp_path, capsys):
    """v10.0.0 must be chosen over v9.0.0 (lexical sort picks v9)."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True, version="v9.0.0")
    broken = make_project(tmp_path / "q", "standard", chain="standard", fill=True, version="v10.0.0")
    # Break v10.0.0 only: orphan P### whose parent exists nowhere.
    conception = broken / "SDLC_PM" / "v10.0.0" / "3_conception.md"
    conception.write_text(
        FILLED_CONCEPTION_E_ONLY.replace("P001:E001", "P001:A999"), encoding="utf-8"
    )
    shutil.copytree(broken / "SDLC_PM" / "v10.0.0", project / "SDLC_PM" / "v10.0.0")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert "v10.0.0" in out, out
    assert code == 1, out


def test_5_8_invalid_config_json_returns_error_code_2(tmp_path, capsys):
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    (project / "SDLC_PM" / "sdlc-config.json").write_text("{ not json", encoding="utf-8")
    code = check_sdlc.check_traceability(project)
    assert code == 2, capsys.readouterr().out


# --- 5.10: ASVS requirement per tier --------------------------------------


def test_5_10a_full_requires_asvs_level_1(tmp_path, capsys):
    project = make_project(tmp_path / "p", "full", asvs=0, chain="strict", fill=True)
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "asvs" in out.lower(), out


def test_5_10b_exhaustive_requires_asvs_level_2(tmp_path, capsys):
    project = make_project(tmp_path / "p", "exhaustive", asvs=1, chain="strict", fill=True)
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "asvs" in out.lower(), out


# --- 5.11: none tier -------------------------------------------------------


def test_5_11_none_tier_is_skipped_not_passed(tmp_path, capsys):
    """D2: none tier checks nothing, reports SKIPPED, exit 0, never PASS."""
    project = make_project(tmp_path / "p", "none", chain="none")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out
    assert "SKIPPED" in out, out
    assert "AQ PASS" not in out, out


# --- 5.13: no false positive on legitimate angle brackets -----------------


def test_5_13_angle_brackets_in_code_block_are_not_placeholders(tmp_path, capsys):
    """Guard test: legacy project (no tier, strict chain) must keep passing."""
    project = make_project(tmp_path / "p", None, chain="strict", fill=True)
    vdir = project / "SDLC_PM" / "v1.0.0"
    (vdir / "1_elicitation.md").write_text(
        FILLED_ELICITATION
        + "\n```python\nfoo: list[<T>] = []\n```\n"
        + "\nDescription: returns a <list> of rows.\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out


# --- 5.14: JSON wrapper (PowerShell) ---------------------------------------


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_14_wrapper_reports_fail_for_untouched_templates(tmp_path):
    project = make_project(tmp_path / "p", "standard", fill=False, chain="strict")
    result = subprocess.run(
        [_pwsh(), "-NoProfile", "-File", str(PS1), "-Json", "-ProjectRoot", str(project)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    data = json.loads(result.stdout)
    assert result.returncode == 1, result.stdout
    assert data["status"] == "FAIL", data
    assert data["exitCode"] == 1, data
    assert any("placeholder" in e.lower() for e in data["errors"]), data


def _run_wrapper(project: Path) -> dict:
    result = subprocess.run(
        [_pwsh(), "-NoProfile", "-File", str(PS1), "-Json", "-ProjectRoot", str(project)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    return {"code": result.returncode, **json.loads(result.stdout)}


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_11_wrapper_reports_skipped_for_none_tier(tmp_path):
    """D2 through the wrapper: none tier is SKIPPED, never PASS."""
    project = make_project(tmp_path / "p", "none", chain="none")
    data = _run_wrapper(project)
    assert data["code"] == 0, data
    assert data["status"] == "SKIPPED", data


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_12_wrapper_exposes_warnings_without_changing_status(tmp_path):
    """D3 through the wrapper: stale HANDOFF is a warning in JSON, status stays PASS."""
    project = make_project(
        tmp_path / "p",
        "standard",
        chain="standard",
        fill=True,
        handoff_day=date.today() - timedelta(days=30),
    )
    data = _run_wrapper(project)
    assert data["code"] == 0, data
    assert data["status"] == "PASS", data
    assert any("HANDOFF" in w for w in data["warnings"]), data


# --- Inspection 3 corrections (R01 to R05) --------------------------------

REAL_CONCEPTION_PLACEHOLDER = "- **Description** : `<actionable sentence, 1-2 lines>`"


def _full_project_with_shipped_tests(root: Path) -> Path:
    """Full project at the planning stage: shipped tests template left in place, P001 only."""
    project = make_project(root, "full", asvs=1, chain="strict", fill=True)
    shutil.copy(ASSETS / "4_tests.template.md", project / "SDLC_PM" / "v1.0.0" / "4_tests.md")
    return project


def test_5_25_planning_phase_ignores_shipped_tests_template(tmp_path, capsys):
    """R01: the shipped T003:P002 template must not orphan a planning-phase project."""
    project = _full_project_with_shipped_tests(tmp_path / "p")
    assert check_sdlc.check_traceability(project, phase="plan") == 0, capsys.readouterr().out
    assert check_sdlc.check_traceability(project, phase="release") == 1, capsys.readouterr().out


@pytest.mark.parametrize("fence", ["```markdown", "~~~markdown"])
def test_5_26_indented_fence_with_real_template_line_is_not_a_placeholder(tmp_path, capsys, fence):
    """R03: fences indented by up to three spaces are code blocks."""
    closing = "   ```" if fence.startswith("```") else "   ~~~"
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED
        + f"\n   {fence}\n{REAL_CONCEPTION_PLACEHOLDER}\n{closing}\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_27_real_template_line_outside_a_fence_is_a_placeholder(tmp_path, capsys):
    """R03 (control): the same real template line outside a fence is still an error."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + f"\n{REAL_CONCEPTION_PLACEHOLDER}\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out


def _wrapper(project: Path, *extra: str) -> dict:
    result = subprocess.run(
        [_pwsh(), "-NoProfile", "-File", str(PS1), "-Json", "-ProjectRoot", str(project), *extra],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    return {"code": result.returncode, **json.loads(result.stdout)}


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_28_wrapper_forwards_phase_plan(tmp_path):
    """R04: -Phase plan reaches the Python gate (parity with the CLI)."""
    project = _full_project_with_shipped_tests(tmp_path / "p")
    data = _wrapper(project, "-Phase", "plan")
    assert data["code"] == 0, data
    assert data["status"] == "PASS", data


@pytest.mark.skipif(not _pwsh(), reason="PowerShell not available")
def test_5_29_wrapper_forwards_today(tmp_path):
    """R04: -Today reaches the HANDOFF age check (19 days here)."""
    project = make_project(
        tmp_path / "p", "minimal", chain="none", fill=True, handoff_day=date(2026, 11, 1)
    )
    data = _wrapper(project, "-Today", "2026-11-20")
    assert data["code"] == 0, data
    assert any("19 days" in w for w in data["warnings"]), data


def test_5_31_author_with_email_in_angle_brackets_is_not_a_placeholder(tmp_path, capsys):
    """Inspection 4, R03: a filled author line may contain `<...>` (an email)."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "HANDOFF.md").write_text(
        f"# HANDOFF\n\n- **Last updated** : {date.today().isoformat()} 10:30 by Alice <alice@example.com>\n\n"
        "## Next 3 actions\n1. Run tests.\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_32_untouched_optional_templates_at_standard_count_as_not_created(tmp_path, capsys):
    """Inspection 4, R04: deploy_init copies all templates; untouched optional ones are not authored."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    vdir = project / "SDLC_PM" / "v1.0.0"
    shutil.copy(ASSETS / "2_architecture.template.md", vdir / "2_architecture.md")
    shutil.copy(ASSETS / "4_tests.template.md", vdir / "4_tests.md")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_33_partly_authored_optional_document_is_still_validated(tmp_path, capsys):
    """Inspection 4, R04 (control): an optional document that was started is checked."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    vdir = project / "SDLC_PM" / "v1.0.0"
    template = (ASSETS / "2_architecture.template.md").read_text(encoding="utf-8")
    (vdir / "2_architecture.md").write_text(
        template.replace("### A001:E001", "### A001:E001 — x", 1) + "\n### A009:E001 — started\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out


def test_5_34_planning_ignores_an_unreadable_tests_document(tmp_path, capsys):
    """Inspection 5, R03: at phase plan, 4_tests.md is not read at all (invalid UTF-8 here)."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    (project / "SDLC_PM" / "v1.0.0" / "4_tests.md").write_bytes(b"\xff\xfe invalid utf-8 \x80")
    code = check_sdlc.check_traceability(project, phase="plan")
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_35_untouched_bootstrap_command_block_in_resume_fails(tmp_path, capsys):
    """Inspection 5, R02: the required setup commands in RESUME are not exempt as examples."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n```bash\n<command>\n<test command>\n```\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "RESUME.md" in out, out


def test_5_36_filled_command_block_in_resume_passes(tmp_path, capsys):
    """Inspection 5, R02 (control): a filled command block is content."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n```bash\npython -m pytest\n```\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


HOW_TO_RESUME_TEMPLATE_LINES = (
    "## How to resume (copy-paste)\n\n```\n1. cd <project path>\n"
    "2. <command to activate the venv / install dependencies>\n"
    "3. <command to run the tests — must pass today>\n"
    "4. Read RESUME.md, then 0_context.md (tier — standard)\n"
    "5. Resume at action 1 above\n```\n"
)


def test_5_37_unlabelled_resume_block_in_handoff_is_checked(tmp_path, capsys):
    """Inspection 7, R01 (61.2): a bootstrap block without a language is required content."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "HANDOFF.md").write_text(
        f"# HANDOFF\n\n- **Last updated** : {date.today().isoformat()} by tester\n\n"
        + HOW_TO_RESUME_TEMPLATE_LINES,
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "HANDOFF.md" in out, out


def test_5_38_filled_unlabelled_block_passes(tmp_path, capsys):
    """Control for 5.37: a filled unlabelled block is content."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "HANDOFF.md").write_text(
        f"# HANDOFF\n\n- **Last updated** : {date.today().isoformat()} by tester\n\n"
        "## How to resume (copy-paste)\n\n```\n1. cd /repo\n2. python -m pytest\n```\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out


BUNDLE_TEMPLATES = ASSETS.parent.parent.parent.parent / "bundle" / "templates" / "SDLC_PM" / "v1.0.0"


@pytest.mark.parametrize(
    "name",
    ["1_elicitation", "2_5_discussion", "2_architecture", "3_conception", "4_tests"],
)
def test_5_39_bundle_template_copy_equals_reference_template(name):
    """Plan task 5.4: the copies shipped in bundle/ must not drift from the reference templates."""
    reference = (ASSETS / f"{name}.template.md").read_bytes()
    copy = (BUNDLE_TEMPLATES / f"{name}.md").read_bytes()
    assert copy == reference, f"{name}: bundle copy differs from assets/{name}.template.md"


def test_5_40_unclosed_example_fence_runs_to_end_of_file(tmp_path, capsys):
    """Inspection 9, AQG-002: an unclosed ``` example extends to end of file and is still an example."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n```markdown\n" + REAL_CONCEPTION_PLACEHOLDER + "\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_41_unclosed_command_fence_still_fails(tmp_path, capsys):
    """Inspection 9, AQG-002 (control): an unclosed command block is still checked."""
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "RESUME.md").write_text(
        RESUME_FILLED + "\n```bash\n<command>\n", encoding="utf-8"
    )
    code = check_sdlc.check_traceability(project, today=FIXED_TODAY)
    out = capsys.readouterr().out
    assert code == 1, out


SHIPPED_SKELETONS = Path(__file__).resolve().parent / "fixtures" / "shipped-skeletons"


def test_5_42_previously_shipped_optional_skeletons_count_as_not_created(tmp_path, capsys):
    """Inspection 10, REV-001 (70.1.1): a project created before the change still has the old skeletons."""
    project = make_project(tmp_path / "p", "standard", chain="standard", fill=True)
    vdir = project / "SDLC_PM" / "v1.0.0"
    shutil.copy(SHIPPED_SKELETONS / "2_architecture.template.md", vdir / "2_architecture.md")
    shutil.copy(SHIPPED_SKELETONS / "4_tests.template.md", vdir / "4_tests.md")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 0, out


def test_5_43_wrapper_script_has_a_utf8_bom_for_windows_powershell_51(tmp_path):
    """Inspection 10, REV-002 (70.2): without a BOM, Windows PowerShell 5.1 misreads the emoji literals."""
    assert PS1.read_bytes().startswith(b"\xef\xbb\xbf"), "check_sdlc.ps1 must be saved as UTF-8 with BOM"


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell 5.1 not available")
def test_5_44_wrapper_runs_under_windows_powershell_51(tmp_path):
    """Inspection 10, REV-002: the wrapper also runs under powershell.exe (5.1), not only pwsh."""
    project = make_project(tmp_path / "p", "none", chain="none")
    result = subprocess.run(
        # -ExecutionPolicy Bypass only for this test process: Windows PowerShell 5.1 blocks unsigned
        # scripts under the default policy on some machines. Not a change to the user's policy.
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(PS1), "-Json",
         "-ProjectRoot", str(project)],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    data = json.loads(result.stdout)
    assert data["status"] == "SKIPPED", data


def test_5_45_chain_documents_made_only_of_fenced_examples_fail(tmp_path, capsys):
    """Inspection 11, REV-001: example IDs inside code blocks are not authored traceability."""
    project = make_project(tmp_path / "p", "full", asvs=1, chain="strict", fill=True)
    vdir = project / "SDLC_PM" / "v1.0.0"
    for name in ("1_elicitation", "2_architecture", "3_conception", "4_tests"):
        text = (ASSETS / f"{name}.template.md").read_text(encoding="utf-8")
        (vdir / f"{name}.md").write_text("```markdown\n" + text + "\n```\n", encoding="utf-8")
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out


def test_5_30_multiline_template_placeholder_span_is_detected(tmp_path, capsys):
    """R05: a `<...>` placeholder that spans several lines in HANDOFF.template.md is detected."""
    lines = (ASSETS / "HANDOFF.template.md").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip().startswith("`<Exact state"))
    end = next(i for i in range(start, len(lines)) if lines[i].strip().endswith(">`"))
    span = "\n".join(lines[start : end + 1])
    project = make_project(tmp_path / "p", "minimal", chain="none", fill=True)
    (project / "SDLC_PM" / "HANDOFF.md").write_text(
        f"# HANDOFF\n\n- **Last updated** : {date.today().isoformat()} by tester\n\n"
        f"## Where things stand (10 lines max)\n\n{span}\n\n## Next 3 actions\n1. Run tests.\n",
        encoding="utf-8",
    )
    code = check_sdlc.check_traceability(project)
    out = capsys.readouterr().out
    assert code == 1, out
    assert "placeholder" in out.lower(), out
