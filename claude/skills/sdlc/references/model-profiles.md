# Dynamic model profiles

Configurable `agent → model` resolution with automatic escalation on soft failure. Implemented by
`scripts/model_profiler.py`. A second axis, **effort**, is set per agent tier in the agent
frontmatter (see [Effort](#effort)).

## Semantic agent tiers

Each agent belongs to a tier (source: `AGENT_TIERS` in `model_profiler.py`; unknown agents fall
back to `exec`):

| Tier | Description | Agents |
|---|---|---|
| `simple` | Simple parsing/extraction/admin work | wave-orchestrator, code-auditor, archive-manager |
| `exec` | Code implementation, tests, analysis | python-dev, js-dev, go-dev, rust-dev, business-analyst, system-analyst, test-designer, security-asvs, quality-assessor |
| `design` | Critical decisions, architecture | architect, discussion-facilitator |

`wave-orchestrator` and `security-asvs` are sub-skills, not agent files; they are listed because
`model_profiler.py` can resolve a model for them.

## Profile × tier matrix

| Profile | simple | exec | design |
|---|---|---|---|
| `budget` | Haiku | Haiku | Sonnet |
| `balanced` (default) | Haiku | Sonnet | Opus |
| `quality` | Sonnet | Opus | Opus |
| `inherit` | (session model) | (session model) | (session model) |

Model IDs: Haiku = `claude-haiku-4-5`, Sonnet = `claude-sonnet-5`, Opus = `claude-opus-5-5`.

## Per-agent override

In `sdlc-config.json`:

```json
{
  "model_profile": "balanced",
  "model_overrides": {
    "sdlc-architect": "claude-opus-5-5",
    "sdlc-rust-dev": "claude-sonnet-5"
  }
}
```

An override always wins over the profile, which allows targeted tuning.

## Soft-failure escalation

With `soft_failure_escalation: true` (default), an agent that fails on a tier-N model retries
**once** on tier N+1:

```
Haiku  → Sonnet (retry 1)
Sonnet → Opus   (retry 1)
Opus   → Opus   (no escalation — already at the top)
```

Escalation counts toward `max_retry_per_task` but not toward the 🔁/🚫 status. A P### can
therefore consume up to (max_retry × 2) attempts when escalating.

## Effort

Effort controls how much the model thinks and how thoroughly it works. In v4.0 it replaces
"think step by step" / "reason carefully" prose in prompts.

| Tier | `effort` | Agents |
|---|---|---|
| `simple` | `low` | code-auditor, archive-manager |
| `exec` | `medium` | python-dev, js-dev, go-dev, rust-dev, business-analyst, system-analyst, test-designer, quality-assessor |
| `design` | `high` | architect, discussion-facilitator |

- **Where it is set**: the `effort:` key in each agent's frontmatter
  (`claude/agents/sdlc-*.md`; Claude Code accepts `low|medium|high|xhigh|max`). It is not a
  `sdlc-config.json` field and `model_profiler.py` does not resolve it. To change it, edit the
  agent file.
- **Why medium for `exec`**: `medium` is the Opus 5.5 default, and at `medium` Opus 5.5 performs
  roughly like Opus 5 at `high`.
- **Less thinking**: to make an agent faster or cheaper, lower its effort rather than adding
  "be brief / don't overthink" to the prompt.
- **`xhigh` / `max`**: reserve them for agents where you have measured a gain; they cost more
  time and tokens.
- Effort applies to whichever model the profile resolves, but the available levels depend on the
  model (see the Claude Code subagent docs). If you run the `budget` profile, check that the
  model resolved for each agent supports the level set in its frontmatter.

## Which profile when

| Case | Recommended profile |
|---|---|
| Quick prototype, MVP | `budget` |
| Standard professional project | `balanced` |
| Critical production, security | `quality` |
| Multi-project work with a strong main session | `inherit` |

## Relative cost

Rough ordering only — check current Anthropic pricing before relying on it:
`budget` < `balanced` < `quality`. `budget` is noticeably cheaper because `exec` agents (most
of the work) run on Haiku; `quality` is the most expensive because `exec` agents run on Opus.
Effort also changes cost: higher effort means more thinking tokens on the same model.

## Direct CLI usage

```powershell
$env:PYTHONUTF8 = "1"

# Resolve an agent's model
python skills/sdlc/scripts/model_profiler.py resolve `
  --agent sdlc-architect `
  --config SDLC_PM/sdlc-config.json
# → {"agent": "sdlc-architect", "model": "claude-opus-5-5", ...}

# Escalate a model
python skills/sdlc/scripts/model_profiler.py escalate `
  --from claude-haiku-4-5
# → {"from": "claude-haiku-4-5", "to": "claude-sonnet-5", "escalated": true}
```

## Integration with the Agent tool

When a subagent is spawned for a P###, the caller:

1. reads the project config,
2. resolves the model with `model_profiler.py resolve`,
3. passes it in the `model` parameter of the `Agent` tool:

```python
Agent(
    description="Implement P003",
    subagent_type="sdlc-python-dev",  # or another
    model=resolved_model,  # e.g. "sonnet" / "opus" / "haiku"
    prompt="...",
)
```

The `Agent` tool accepts the short names `haiku`/`sonnet`/`opus` in its `model` parameter:

| Full ID | Agent tool short name |
|---|---|
| `claude-haiku-4-5` | `haiku` |
| `claude-sonnet-5` | `sonnet` |
| `claude-opus-5-5` | `opus` |

The effort comes from the spawned agent's frontmatter; the caller does not pass it.

## Disabling profiles (legacy mode)

`model_profile: "inherit"` without `model_overrides` reproduces the "everything on the main
session model" behavior — useful for debugging, or where running several tiers is not wanted.
