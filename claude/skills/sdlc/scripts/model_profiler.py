"""model_profiler.py — SDLC model profile resolver.

Model IDs: claude-haiku-4-5 (Haiku), claude-sonnet-5 (Sonnet),
claude-opus-5-5 (Opus).

Profiles (agent tiers: simple / exec / design):
  budget    → Haiku / Haiku / Sonnet (cost first)
  balanced  → Haiku / Sonnet / Opus (default)
  quality   → Sonnet / Opus / Opus (quality first)
  inherit   → the main session's model (passed via --session-model)

Reasoning depth is set separately by the `effort:` key in each agent's
frontmatter, not by this resolver.

Soft-failure escalation (when soft_failure_escalation=true):
  Haiku → Sonnet (1 retry) → Sonnet (final)
  Sonnet → Opus (1 retry) → Opus (final)
  Opus → Opus (no escalation)

CLI usage:
  python model_profiler.py resolve --agent sdlc-architect --config sdlc-config.json
  python model_profiler.py escalate --from claude-haiku-4-5
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")


HAIKU = "claude-haiku-4-5"
SONNET = "claude-sonnet-5"
OPUS = "claude-opus-5-5"

ESCALATION = {HAIKU: SONNET, SONNET: OPUS, OPUS: OPUS}

# Agent → semantic tier mapping, used to resolve a model from the profile.
# Tiers: "simple" (admin/parsing/extraction), "exec" (code implementation,
# tests), "design" (architecture, critical decisions).
AGENT_TIERS: dict[str, str] = {
    "sdlc-business-analyst": "exec",
    "sdlc-architect": "design",
    "sdlc-discussion-facilitator": "design",
    "sdlc-system-analyst": "exec",
    "sdlc-wave-orchestrator": "simple",
    "sdlc-python-dev": "exec",
    "sdlc-js-dev": "exec",
    "sdlc-go-dev": "exec",
    "sdlc-rust-dev": "exec",
    "sdlc-test-designer": "exec",
    "sdlc-security-asvs": "exec",
    "sdlc-quality-assessor": "exec",
    "sdlc-code-auditor": "simple",
    "sdlc-archive-manager": "simple",
}

PROFILE_MATRIX: dict[str, dict[str, str]] = {
    "budget":   {"simple": HAIKU,  "exec": HAIKU,  "design": SONNET},
    "balanced": {"simple": HAIKU,  "exec": SONNET, "design": OPUS},
    "quality":  {"simple": SONNET, "exec": OPUS,   "design": OPUS},
}


def resolve_model(agent: str, config: dict, session_model: str | None = None) -> str:
    """Resolve the model for a given agent.

    Precedence:
      1. config.model_overrides[agent] when present
      2. "inherit" profile → session_model
      3. profile + the agent's semantic tier
    """
    overrides = config.get("model_overrides", {}) or {}
    if agent in overrides:
        return overrides[agent]
    profile = config.get("model_profile", "balanced")
    if profile == "inherit":
        if not session_model:
            return SONNET
        return session_model
    tier = AGENT_TIERS.get(agent, "exec")
    matrix = PROFILE_MATRIX.get(profile, PROFILE_MATRIX["balanced"])
    return matrix.get(tier, SONNET)


def escalate(model: str, allowed: bool = True) -> str:
    """Return the model one tier up (unchanged when not allowed or already at the top)."""
    if not allowed:
        return model
    return ESCALATION.get(model, model)


def cmd_resolve(args: argparse.Namespace) -> int:
    config = json.loads(Path(args.config).read_text(encoding="utf-8")) if args.config else {}
    model = resolve_model(args.agent, config, session_model=args.session_model)
    print(json.dumps({"agent": args.agent, "model": model, "profile": config.get("model_profile", "balanced")}, ensure_ascii=False))
    return 0


def cmd_escalate(args: argparse.Namespace) -> int:
    config = json.loads(Path(args.config).read_text(encoding="utf-8")) if args.config else {}
    allowed = bool(config.get("soft_failure_escalation", True)) if config else True
    new_model = escalate(args.from_model, allowed=allowed)
    print(json.dumps({"from": args.from_model, "to": new_model, "escalated": new_model != args.from_model}, ensure_ascii=False))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="SDLC model profile resolver")
    sub = parser.add_subparsers(dest="cmd", required=True)

    resolve_p = sub.add_parser("resolve", help="Resolve the model for an agent")
    resolve_p.add_argument("--agent", required=True)
    resolve_p.add_argument("--config", default=None, help="Path to sdlc-config.json")
    resolve_p.add_argument("--session-model", default=None, help="Session model, used by the inherit profile")

    escalate_p = sub.add_parser("escalate", help="Escalate a model by one tier")
    escalate_p.add_argument("--from", dest="from_model", required=True)
    escalate_p.add_argument("--config", default=None)

    args = parser.parse_args()
    if args.cmd == "resolve":
        return cmd_resolve(args)
    if args.cmd == "escalate":
        return cmd_escalate(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
