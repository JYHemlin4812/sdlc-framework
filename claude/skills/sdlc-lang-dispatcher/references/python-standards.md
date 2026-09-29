# Python standards (SDLC)

## Expected environment

- **Python ≥ 3.11** (SDLC itself is tested on 3.13)
- **Package manager**: `uv` (`uv add`, `uv run`, `uv sync`) — preferred over pip
- **Encoding**: UTF-8 everywhere, `$env:PYTHONUTF8 = "1"` on Windows
- **Paths**: `pathlib.Path` only, never string paths

## Standard tools

| Task | Tool |
|---|---|
| Linter | `ruff check` |
| Formatter | `ruff format` |
| Type checker | `mypy --strict` (or `pyright`) |
| Tests | `pytest` |
| Coverage | `pytest --cov` |
| Runtime validation | `pydantic` v2 |

## Required style

```python
from __future__ import annotations  # always first

from pathlib import Path
from typing import Sequence  # not typing.List; use list[X]

def parse_csv(path: Path) -> list[dict[str, str]]:
    """Parse a CSV file and return its rows."""
    if not path.exists():
        raise FileNotFoundError(f"CSV not found: {path}")
    return ...
```

Firm rules:

- ✅ **Type hints** on every public function (parameters and return)
- ✅ **Docstring** on every public function (one line minimum)
- ✅ **Validate at the boundary**: Pydantic on input, plain types internally
- ✅ **`__all__`** in every module exposing an API
- ✅ **Logging** via `logging` or `loguru`, not `print` in production
- ❌ **No bare `except:`** — always `except SpecificError:` or `except Exception:` with
  re-raise / log
- ❌ **No `os.system()`** — use `subprocess.run` with `shell=False`
- ❌ **No hardcoded absolute paths** — use `pathlib` + config
- ❌ **No circular imports** — restructure rather than adding late imports
- ❌ **No silent mutation** — prefer methods that return a new value

## Tests

- **Framework**: `pytest` only
- **Naming**: `test_<function>_<scenario>` (e.g. `test_parse_csv_empty_file`)
- **Fixtures**: prefer `tmp_path`, `monkeypatch`
- **Coverage target**: 70% minimum (configurable via `test_coverage_min`)
- **Required edge cases**: empty input, None, extreme value, wrong type

## Recommended project layout

```
project/
├── pyproject.toml         # uv-managed
├── src/
│   └── mypkg/
│       ├── __init__.py
│       └── module.py
├── tests/
│   ├── conftest.py
│   └── test_module.py
└── README.md
```

## Typical commands

```powershell
# Setup
uv init
uv add pydantic pytest ruff mypy

# Dev loop
uv run ruff check src/ tests/
uv run ruff format src/ tests/
uv run mypy src/
uv run pytest --cov=src

# Run
uv run python -m mypkg.module
```

## Forbidden anti-patterns

```python
# ❌ Bad
def f(x):
    try:
        return x.upper()
    except:
        pass

# ✅ Good
def f(x: str | None) -> str | None:
    if x is None:
        return None
    return x.upper()
```

```python
# ❌ Bad
import os
os.system("rm -rf " + user_input)

# ✅ Good
import subprocess
from pathlib import Path
target = Path(user_input).resolve()
if target.is_relative_to(SAFE_DIR):
    subprocess.run(["rm", "-rf", str(target)], check=True)
```

## Windows specifics

- Set `$env:PYTHONUTF8 = "1"` before any script that may print emoji (ASVS, SDLC status
  emoji)
- `pathlib.Path` handles `\` vs `/` automatically
- No `os.path.join` — use `Path / "subdir" / "file.ext"`

## Recommended commit message for a P###

```
P003: parse_csv handles BOM and trailing newlines

Implements P003:A001 — adds BOM detection in parse_csv() and
normalizes trailing newlines. Tests T010, T011 added.
```
