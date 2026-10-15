"""Unit tests for worktree_helper.py (real git repos in tmp_path)."""

from __future__ import annotations

import subprocess
import sys
from argparse import Namespace
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import worktree_helper as wh  # noqa: E402

CONCEPTION = """\
#### P001
- **Depends on**: none
- **Target files**: src/app.py

#### P002
- **Depends on**: none
- **Target files**: src/app.py, src/b.py

#### P003
- **Depends on**: P001
- **Target files**: src/c.py
"""


def run(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True
    ).stdout


@pytest.fixture()
def repo(tmp_path: Path) -> Path:
    run(tmp_path, "init", "-q", "-b", "main")
    run(tmp_path, "config", "user.name", "t")
    run(tmp_path, "config", "user.email", "t@t")
    (tmp_path / "a.txt").write_text("base\n", encoding="utf-8")
    run(tmp_path, "add", "-A")
    run(tmp_path, "commit", "-q", "-m", "init")
    return tmp_path


def ns(**kw) -> Namespace:
    return Namespace(allow_dirty=False, **kw)


def test_select_modes():
    layer = ["P002", "P001"]
    conflict = [{"wave": 1, "tasks": ["P001", "P002"], "files": ["x"]}]
    assert wh.select_isolated("off", layer, conflict) == []
    assert wh.select_isolated("on", layer, []) == ["P001", "P002"]
    assert wh.select_isolated("auto", layer, []) == []
    assert wh.select_isolated("auto", layer, conflict) == ["P001", "P002"]
    assert wh.select_isolated("on", ["P001"], conflict) == []  # nothing to isolate from


def test_select_from_conception(tmp_path: Path):
    f = tmp_path / "3_conception.md"
    f.write_text(CONCEPTION, encoding="utf-8")
    auto = wh.cmd_select(Namespace(conception=str(f), wave=1, mode="auto"))
    assert auto["isolate"] == ["P001", "P002"]
    assert auto["write_conflicts"][0]["files"] == ["src/app.py"]
    assert wh.cmd_select(Namespace(conception=str(f), wave=2, mode="on"))["isolate"] == []
    with pytest.raises(wh.HelperError):
        wh.cmd_select(Namespace(conception=str(f), wave=9, mode="auto"))


def test_create_merge_cleanup(repo: Path):
    info = wh.cmd_create(ns(root=str(repo), task="P001"))
    wt = Path(info["path"])
    assert wt.is_dir() and info["branch"] == "sdlc/P001"
    assert "/.sdlc-worktrees/" in (repo / ".git" / "info" / "exclude").read_text(encoding="utf-8")
    (wt / "new.txt").write_text("p001\n", encoding="utf-8")  # uncommitted: merge commits it
    out = wh.cmd_merge(ns(root=str(repo), task="P001"))
    assert out == {"task": "P001", "merged": True, "conflicts": []}
    assert (repo / "new.txt").read_text(encoding="utf-8") == "p001\n"
    gone = wh.cmd_cleanup(ns(root=str(repo), task="P001"))
    assert gone["worktree_removed"] and gone["branch_deleted"]
    assert not wt.exists()


def test_merge_conflict_aborts_and_leaves_root_clean(repo: Path):
    one = Path(wh.cmd_create(ns(root=str(repo), task="P001"))["path"])
    two = Path(wh.cmd_create(ns(root=str(repo), task="P002"))["path"])
    (one / "a.txt").write_text("one\n", encoding="utf-8")
    (two / "a.txt").write_text("two\n", encoding="utf-8")
    assert wh.cmd_merge(ns(root=str(repo), task="P001"))["merged"] is True
    out = wh.cmd_merge(ns(root=str(repo), task="P002"))
    assert out["merged"] is False and out["conflicts"] == ["a.txt"]
    assert run(repo, "status", "--porcelain", "--untracked-files=no").strip() == ""
    assert (repo / "a.txt").read_text(encoding="utf-8") == "one\n"


def test_create_refuses_dirty_tree_and_bad_ids(repo: Path):
    (repo / "a.txt").write_text("dirty\n", encoding="utf-8")
    with pytest.raises(wh.HelperError):
        wh.cmd_create(ns(root=str(repo), task="P001"))
    with pytest.raises(wh.HelperError):
        wh.check_task("../evil")
