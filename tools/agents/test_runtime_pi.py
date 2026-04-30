"""Unit tests for the pi branch of tools.agents._runtime.

These are pure-function tests: no subprocess, no network, no API keys.
They exercise:
  - build_agent_cmd argv shape for provider="pi"
  - PI_MODEL env-var requirement
  - _summarize_pi_jsonl parser for the events we expect from pi --mode json
  - get_provider() acceptance of "pi"
"""
from __future__ import annotations

import os
from unittest import mock

import pytest

from tools.agents import _runtime


# --- get_provider -------------------------------------------------------


def test_get_provider_accepts_pi(monkeypatch):
    monkeypatch.setenv("AGENT_PROVIDER", "pi")
    assert _runtime.get_provider() == "pi"


def test_get_provider_rejects_unknown(monkeypatch):
    monkeypatch.setenv("AGENT_PROVIDER", "ollama")
    with pytest.raises(ValueError):
        _runtime.get_provider()


def test_valid_providers_includes_pi():
    assert "pi" in _runtime.VALID_PROVIDERS


# --- build_agent_cmd ----------------------------------------------------


def test_build_agent_cmd_pi_argv_shape(monkeypatch):
    monkeypatch.setenv("PI_MODEL", "anthropic/claude-opus-4-7")
    cmd = _runtime.build_agent_cmd("hello world", cwd=".", provider="pi")
    # Must be exactly this shape — the bench runner depends on it.
    assert cmd[0] == "pi"
    assert cmd[1:3] == ["-p", "hello world"]
    assert "--mode" in cmd and cmd[cmd.index("--mode") + 1] == "json"
    assert "--model" in cmd
    assert cmd[cmd.index("--model") + 1] == "anthropic/claude-opus-4-7"
    assert "--tools" in cmd
    assert cmd[cmd.index("--tools") + 1] == "read,write,edit,bash,grep,find,ls"


def test_build_agent_cmd_pi_explicit_model_kwarg_overrides_env(monkeypatch):
    monkeypatch.setenv("PI_MODEL", "anthropic/claude-opus-4-7")
    cmd = _runtime.build_agent_cmd(
        "hi", cwd=".", provider="pi", model="openai/gpt-5"
    )
    assert cmd[cmd.index("--model") + 1] == "openai/gpt-5"


def test_build_agent_cmd_pi_requires_model(monkeypatch):
    monkeypatch.delenv("PI_MODEL", raising=False)
    with pytest.raises(ValueError, match="PI_MODEL"):
        _runtime.build_agent_cmd("hi", cwd=".", provider="pi")


def test_build_agent_cmd_pi_does_not_take_output_last_message(monkeypatch):
    """Pi has its own session storage; output_last_message is a codex-only kwarg."""
    monkeypatch.setenv("PI_MODEL", "anthropic/claude-opus-4-7")
    # Should not raise even though we pass output_last_message
    # (pi simply ignores it).
    cmd = _runtime.build_agent_cmd(
        "hi", cwd=".", provider="pi",
        output_last_message="/tmp/last.txt",
    )
    assert cmd[0] == "pi"
    # And the path should NOT appear in the argv anywhere.
    assert "/tmp/last.txt" not in cmd


# --- _summarize_pi_jsonl ------------------------------------------------


def test_summarize_pi_tool_call_with_file_path():
    ev = {"type": "tool_call", "name": "edit",
          "input": {"file_path": "cores/bench/rtl/alu.sv"}}
    assert _runtime._summarize_pi_jsonl(ev) == "edit: cores/bench/rtl/alu.sv"


def test_summarize_pi_tool_call_with_bash_command():
    ev = {"type": "tool_call", "name": "bash",
          "input": {"command": "verilator --lint-only rtl/*.sv"}}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert out.startswith("bash:")
    assert "verilator" in out


def test_summarize_pi_tool_call_truncates_long_targets():
    long = "/very/long/path/" + "x" * 200
    ev = {"type": "tool_call", "name": "read", "input": {"file_path": long}}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert len(out) < 110  # truncation hits at 100


def test_summarize_pi_thread_control_events_suppressed():
    for et in ("thread.started", "thread.completed",
               "turn.started", "turn.completed", "tool_result"):
        assert _runtime._summarize_pi_jsonl({"type": et}) is None


def test_summarize_pi_assistant_message():
    ev = {"type": "assistant_message", "text": "Hello\nworld"}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert "Hello" in out
    assert "world" not in out  # only first line


def test_summarize_pi_error_event():
    ev = {"type": "error", "message": "rate limit exceeded"}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert "rate limit" in out


def test_summarize_pi_usage_event():
    ev = {"type": "usage", "input_tokens": 1234,
          "output_tokens": 567, "cost_usd": 0.42}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert "1234" in out
    assert "567" in out
    assert "0.42" in out


def test_summarize_pi_unknown_type_surfaces_for_followup():
    ev = {"type": "frobnicate"}
    out = _runtime._summarize_pi_jsonl(ev)
    assert out is not None
    assert "frobnicate" in out


# --- summarize_event end-to-end (pi provider) ---------------------------


def test_summarize_event_pi_jsonl_line():
    line = '{"type":"tool_call","name":"edit","input":{"file_path":"foo.sv"}}\n'
    assert _runtime.summarize_event(line, provider="pi") == "edit: foo.sv"


def test_summarize_event_pi_plain_text_fallback():
    line = "Some banner text from pi startup\n"
    out = _runtime.summarize_event(line, provider="pi")
    assert out is not None
    assert "banner" in out


def test_summarize_event_pi_blank_line():
    assert _runtime.summarize_event("\n", provider="pi") is None
    assert _runtime.summarize_event("", provider="pi") is None
