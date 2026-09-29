---
name: sdlc-lang-dispatcher
description: |
  SDLC sub-skill: routes each P### to the right language standards and dev agent.
  Loads the matching reference (Python, JavaScript/TypeScript, Go, Rust) and picks
  the dev subagent (`sdlc-python-dev`, `sdlc-js-dev`, `sdlc-go-dev`, `sdlc-rust-dev`)
  from the task's `Language` field or the project's `primary_language`.

  Triggers: SDLC multi-language, choosing subagent_type, Python/JS/Go/Rust standards
  for SDLC, per-language conventions, package manager, project linter.
  Also triggers on (FR): standards par langage, choix du sous-agent, conventions par langage.
---

# sdlc-lang-dispatcher — per-language routing

Shipped in the SDLC bundle (installable via `scripts/install.ps1` or `scripts/install.sh`).
This sub-skill holds the **per-language standards** for SDLC. When the main skill runs a
P###, it uses this sub-skill to:

1. Pick the `subagent_type` to pass to the `Agent` tool
2. Know which tools to use (package manager, linter, test runner)
3. Apply the expected code conventions

## When to use it

- At the start of every P###, to pick the dev agent and its standards reference
- For diagnostics: checking the consistency of a multi-stack project

## Routing table

| Language | Reference to load | `subagent_type` |
|---|---|---|
| `python` | `references/python-standards.md` | `sdlc-python-dev` |
| `javascript` / `typescript` | `references/js-standards.md` | `sdlc-js-dev` |
| `go` | `references/go-standards.md` | `sdlc-go-dev` |
| `rust` | `references/rust-standards.md` | `sdlc-rust-dev` |

The dev agents live in `claude/agents/` (installed under `~/.claude/agents/`) and read
their standards reference themselves. If a dev agent is not installed, fall back to
`general-purpose` and include the reference's content in the prompt.

## Selection protocol (called from the main skill)

```python
# Conceptual pseudo-code — executed agent-side
def select_lang_route(p_id: str, conception_md: str, config: dict) -> tuple[str, Path]:
    p_section = extract_section(conception_md, p_id)
    # "Langage" is the legacy French field name, still accepted
    lang = (p_section.get("Language") or p_section.get("Langage")
            or config.get("primary_language", "python"))
    routes = {
        "python": ("sdlc-python-dev", "references/python-standards.md"),
        "javascript": ("sdlc-js-dev", "references/js-standards.md"),
        "typescript": ("sdlc-js-dev", "references/js-standards.md"),
        "go": ("sdlc-go-dev", "references/go-standards.md"),
        "rust": ("sdlc-rust-dev", "references/rust-standards.md"),
    }
    agent, ref = routes[lang]
    return agent, Path(__file__).parent / ref
```

The subagent prompt then contains the P### description (and, on the `general-purpose`
fallback, the loaded reference).

## Cross-language standards

Whatever the language, every subagent invoked for a P###:

1. **Checks Code Lock** before writing (P### ✅ + AQ Gate ✅), so every change traces back
   to an approved task.
2. **Commits atomically**: one commit per finished P###.
3. **Uses UTF-8** for all text files.
4. **Respects the existing `.gitignore`**; never commits build output or artifacts.
5. **Applies TDD by task type (doctrine owned by `sdlc-evolve`)**: required — failing test
   first — for any P### touching **production code** (feature, bugfix, refactor);
   recommended/optional for **mechanical** P### (config, scaffolding, generated code,
   throwaway prototype). For production code, see the test fail before writing the code,
   not alongside it.
6. **Documents minimally**: docstrings on public functions; no comments that restate what
   the code does (the name is enough).
7. **Handles errors explicitly**: no bare `except:` (Python), no untyped `catch` (TS), etc.

## Multi-stack projects

If `primary_language: "python"` but a P### has `Language: "typescript"`:

- The task is routed to `sdlc-js-dev` with the TS reference
- The Python linter is not run on `.ts` files
- Tests run via `pnpm test` (or the TS tool) in addition to pytest

The AQ Gate does not distinguish languages in its traceability checks, but the ASVS scanner
applies patterns specific to the scanned file's language (see `asvs_patterns.json`).

## Limitations

- No routing for C/C++/Java/C#/PHP
- No automatic language detection from target files (declare `Language` in the P###)
- No fine-grained version handling (Python 3.11 vs 3.12) — left to the agent

## Further reading

- `references/python-standards.md`
- `references/js-standards.md`
- `references/go-standards.md`
- `references/rust-standards.md`
