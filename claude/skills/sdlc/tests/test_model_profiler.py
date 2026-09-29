"""Unit tests for model_profiler.py."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import model_profiler  # noqa: E402


HAIKU = model_profiler.HAIKU
SONNET = model_profiler.SONNET
OPUS = model_profiler.OPUS


def test_resolve_balanced_architect():
    config = {"model_profile": "balanced"}
    assert model_profiler.resolve_model("sdlc-architect", config) == OPUS


def test_resolve_balanced_python_dev():
    config = {"model_profile": "balanced"}
    assert model_profiler.resolve_model("sdlc-python-dev", config) == SONNET


def test_resolve_budget_python_dev():
    config = {"model_profile": "budget"}
    assert model_profiler.resolve_model("sdlc-python-dev", config) == HAIKU


def test_resolve_quality_simple():
    config = {"model_profile": "quality"}
    assert model_profiler.resolve_model("sdlc-archive-manager", config) == SONNET


def test_resolve_inherit_with_session_model():
    config = {"model_profile": "inherit"}
    out = model_profiler.resolve_model("any-agent", config, session_model=OPUS)
    assert out == OPUS


def test_resolve_inherit_without_session_model_falls_back():
    config = {"model_profile": "inherit"}
    out = model_profiler.resolve_model("any-agent", config)
    assert out == SONNET


def test_resolve_override_wins():
    config = {"model_profile": "budget", "model_overrides": {"sdlc-architect": OPUS}}
    assert model_profiler.resolve_model("sdlc-architect", config) == OPUS


def test_escalate_haiku_to_sonnet():
    assert model_profiler.escalate(HAIKU) == SONNET


def test_escalate_sonnet_to_opus():
    assert model_profiler.escalate(SONNET) == OPUS


def test_escalate_opus_stays_opus():
    assert model_profiler.escalate(OPUS) == OPUS


def test_escalate_disabled():
    assert model_profiler.escalate(HAIKU, allowed=False) == HAIKU


def test_unknown_agent_default_exec_tier():
    """An unknown agent falls back to the 'exec' tier."""
    config = {"model_profile": "balanced"}
    assert model_profiler.resolve_model("unknown-agent", config) == SONNET
