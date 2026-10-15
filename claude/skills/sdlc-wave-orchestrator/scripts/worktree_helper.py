"""worktree_helper.py — Per-task git worktrees for SDLC waves.

Gives each P### of a wave its own git worktree and branch, so parallel
subagents never write into the same working tree, then merges the branches back
one by one after the wave. Stdlib + git only.

Subcommands (JSON on stdout):
  select   Decide which P### of a wave run isolated, from `wave_worktrees`
           (auto | on | off) and the Bernstein linter of wave_planner.py.
  create   `git worktree add` for one P### under <root>/.sdlc-worktrees/<P###>
           on branch sdlc/<P###>, from HEAD.
  merge    Commit pending work of the worktree, then `git merge --no-ff` its
           branch into the current branch of <root>. On conflict the merge is
           aborted and the conflicting files are reported.
  cleanup  Remove the worktree and delete its branch.

Modes (`wave_worktrees` in SDLC_PM/sdlc-config.json, default `auto`):
  off   never isolate
  on    isolate every P### of a wave that has two or more P###
  auto  isolate the whole wave only when it has a declared write conflict

Exit codes:
  0 — Success
  1 — Merge conflict (merge aborted, <root> left clean)
  2 — Input or git error

Usage:
  python worktree_helper.py select --conception SDLC_PM/v1.0.0/3_conception.md --wave 1 --mode auto
  python worktree_helper.py create --root . --task P001
  python worktree_helper.py merge --root . --task P001
  python worktree_helper.py cleanup --root . --task P001
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wave_planner  # noqa: E402

WORKTREE_DIR = ".sdlc-worktrees"
BRANCH_PREFIX = "sdlc/"
TASK_RE = re.compile(r"^P\d{3}$")
MODES = ("auto", "on", "off")
# git needs an identity to commit/merge; supply one without touching the user's config.
IDENTITY = ["-c", "user.name=sdlc-framework", "-c", "user.email=sdlc-framework@localhost"]


class HelperError(Exception):
    """Input or git failure (exit code 2)."""


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["git", "-C", str(cwd), *args], capture_output=True, text=True, encoding="utf-8"
    )
    if check and proc.returncode != 0:
        raise HelperError(f"git {' '.join(args)}: {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


def check_task(task: str) -> str:
    if not TASK_RE.match(task):
        raise HelperError(f"invalid task id {task!r} (expected P###)")
    return task


def worktree_path(root: Path, task: str) -> Path:
    return root / WORKTREE_DIR / task


def select_isolated(mode: str, layer: list[str], conflicts: list[dict]) -> list[str]:
    """Return the P### of `layer` that must run in their own worktree."""
    if mode == "off" or len(layer) < 2:
        return []
    if mode == "on":
        return sorted(layer)
    return sorted(layer) if conflicts else []  # auto


def cmd_select(args: argparse.Namespace) -> dict:
    path = Path(args.conception)
    if not path.exists():
        raise HelperError(f"file not found: {path}")
    content = path.read_text(encoding="utf-8")
    waves, cycles = wave_planner.kahn_layers(wave_planner.parse_dag(content))
    if cycles:
        raise HelperError(f"cycle detected: {cycles}")
    if not 1 <= args.wave <= len(waves):
        raise HelperError(f"wave {args.wave} out of range (1..{len(waves)})")
    conflicts = [
        c
        for c in wave_planner.detect_write_conflicts(waves, wave_planner.parse_write_sets(content))
        if c["wave"] == args.wave
    ]
    isolate = select_isolated(args.mode, waves[args.wave - 1], conflicts)
    return {"wave": args.wave, "mode": args.mode, "isolate": isolate, "write_conflicts": conflicts}


def ensure_excluded(root: Path) -> None:
    """Keep .sdlc-worktrees/ out of git status through .git/info/exclude (untracked, local)."""
    exclude = Path(git(root, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude").stdout.strip())
    exclude.parent.mkdir(parents=True, exist_ok=True)
    line = f"/{WORKTREE_DIR}/"
    current = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
    if line not in current.splitlines():
        exclude.write_text(current + ("" if current.endswith("\n") or not current else "\n") + line + "\n", encoding="utf-8")


def cmd_create(args: argparse.Namespace) -> dict:
    root, task = Path(args.root).resolve(), check_task(args.task)
    dirty = git(root, "status", "--porcelain", "--untracked-files=no", "--", ".", ":(exclude)SDLC_PM").stdout
    if dirty.strip() and not args.allow_dirty:
        raise HelperError("uncommitted tracked changes outside SDLC_PM/: commit them first, a worktree starts from HEAD")
    target = worktree_path(root, task)
    if target.exists():
        raise HelperError(f"worktree already exists: {target}")
    ensure_excluded(root)
    base = git(root, "rev-parse", "HEAD").stdout.strip()
    git(root, "worktree", "add", "-b", BRANCH_PREFIX + task, str(target), base)
    return {"task": task, "path": str(target), "branch": BRANCH_PREFIX + task, "base": base}


def cmd_merge(args: argparse.Namespace) -> dict:
    root, task = Path(args.root).resolve(), check_task(args.task)
    target, branch = worktree_path(root, task), BRANCH_PREFIX + task
    if not target.exists():
        raise HelperError(f"no worktree for {task}: {target}")
    if git(target, "status", "--porcelain").stdout.strip():
        git(target, "add", "-A")
        git(target, *IDENTITY, "commit", "-m", f"sdlc: {task}")
    proc = git(root, *IDENTITY, "merge", "--no-ff", "-m", f"sdlc: merge {task}", branch, check=False)
    if proc.returncode == 0:
        return {"task": task, "merged": True, "conflicts": []}
    files = git(root, "diff", "--name-only", "--diff-filter=U", check=False).stdout.split()
    git(root, "merge", "--abort", check=False)
    return {"task": task, "merged": False, "conflicts": sorted(files)}


def cmd_cleanup(args: argparse.Namespace) -> dict:
    root, task = Path(args.root).resolve(), check_task(args.task)
    removed = git(root, "worktree", "remove", "--force", str(worktree_path(root, task)), check=False)
    branch = git(root, "branch", "-D", BRANCH_PREFIX + task, check=False)
    return {"task": task, "worktree_removed": removed.returncode == 0, "branch_deleted": branch.returncode == 0}


def main() -> int:
    parser = argparse.ArgumentParser(description="Per-task git worktrees for SDLC waves.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("select", help="which P### of a wave run isolated")
    p.add_argument("--conception", required=True, help="Path to 3_conception.md")
    p.add_argument("--wave", type=int, required=True, help="Wave number (1-based)")
    p.add_argument("--mode", choices=MODES, default="auto")
    p.set_defaults(func=cmd_select)

    for name, func in (("create", cmd_create), ("merge", cmd_merge), ("cleanup", cmd_cleanup)):
        p = sub.add_parser(name)
        p.add_argument("--root", default=".", help="Project git root")
        p.add_argument("--task", required=True, help="P### identifier")
        if name == "create":
            p.add_argument("--allow-dirty", action="store_true", help="Skip the clean-tree check")
        p.set_defaults(func=func)

    args = parser.parse_args()
    try:
        result = args.func(args)
    except HelperError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result.get("merged") is False else 0


if __name__ == "__main__":
    sys.exit(main())
