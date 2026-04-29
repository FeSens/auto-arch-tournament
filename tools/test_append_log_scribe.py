"""append_log's scribe integration: _diff strip, lesson population, skip-on-failure.

Exercises the orchestrator-side wiring without invoking real git or a real
agent: subprocess.run, plot_progress, and run_scribe_agent are all stubbed.
The thing we actually want to verify is that append_log:
  1. pops `_diff` from the entry before json.dumps (it must NOT land in JSONL)
  2. populates `lesson` when the scribe returns a string
  3. populates `scribe_skipped` when the scribe raises
"""
import json
import subprocess as real_subprocess
from pathlib import Path

import pytest


@pytest.fixture
def patched_log_env(tmp_path, monkeypatch):
    """Stub out git, plot, and the scribe so append_log can run in-tmp.

    Returns the tmp path where LOG_PATH points; tests read JSONL from there
    to inspect what was written.
    """
    from tools import orchestrator

    log_path = tmp_path / "log.jsonl"
    monkeypatch.setattr(orchestrator, "LOG_PATH", log_path)
    monkeypatch.setattr(orchestrator, "PLOT_PATH", tmp_path / "progress.png")

    # No-op git + plot.
    def _fake_run(cmd, *a, **kw):
        return real_subprocess.CompletedProcess(cmd, 0, "", "")
    monkeypatch.setattr(orchestrator.subprocess, "run", _fake_run)
    monkeypatch.setattr(orchestrator, "plot_progress",
                        lambda *a, **kw: None)

    # Stub _current_target so the scribe path is taken (and predictable).
    monkeypatch.setattr(orchestrator, "_current_target", lambda: "foo")

    return log_path


def _entry(**over):
    return {
        "id": "hyp-test-001",
        "title": "t",
        "category": "structural",
        "outcome": "regression",
        "delta_pct": -1.0,
        "fitness": 290.0,
        "lut4": 3000,
        "ff": 1500,
        "fmax_mhz": 80.0,
        "ipc_coremark": 290.0,
        "implementation_notes": "",
        "_diff": "diff content that should never land in JSONL",
        **over,
    }


def _read_last(log_path: Path) -> dict:
    last = log_path.read_text().splitlines()[-1]
    return json.loads(last)


def test_append_log_strips_diff_before_writing_jsonl(patched_log_env, monkeypatch):
    from tools import orchestrator
    from tools.agents import scribe

    monkeypatch.setattr(scribe, "run_scribe_agent",
                        lambda entry, diff, target: None)
    # Ensure the orchestrator's deferred import sees our patched scribe.
    import sys
    sys.modules["tools.agents.scribe"] = scribe

    orchestrator.append_log(_entry())
    written = _read_last(patched_log_env)
    assert "_diff" not in written
    assert "diff content" not in patched_log_env.read_text()


def test_append_log_records_lesson_when_scribe_returns(patched_log_env, monkeypatch):
    from tools import orchestrator
    from tools.agents import scribe

    bullet = "- 2026-04-29 hyp-test-001 (regression, -1.00%): example lesson"
    monkeypatch.setattr(scribe, "run_scribe_agent",
                        lambda entry, diff, target: bullet)
    import sys
    sys.modules["tools.agents.scribe"] = scribe

    orchestrator.append_log(_entry())
    written = _read_last(patched_log_env)
    assert written.get("lesson") == bullet
    assert "scribe_skipped" not in written


def test_append_log_records_scribe_skipped_on_failure(patched_log_env, monkeypatch):
    from tools import orchestrator
    from tools.agents import scribe

    def boom(entry, diff, target):
        raise TimeoutError("scribe timed out after 120s")
    monkeypatch.setattr(scribe, "run_scribe_agent", boom)
    import sys
    sys.modules["tools.agents.scribe"] = scribe

    orchestrator.append_log(_entry())
    written = _read_last(patched_log_env)
    assert "lesson" not in written
    assert "TimeoutError" in written.get("scribe_skipped", "")
    assert "scribe timed out" in written.get("scribe_skipped", "")


def test_append_log_no_scribe_call_when_target_none(patched_log_env, monkeypatch):
    """Legacy single-core path: _current_target() returns None, so the
    scribe is skipped entirely. The log line still gets written."""
    from tools import orchestrator
    from tools.agents import scribe

    monkeypatch.setattr(orchestrator, "_current_target", lambda: None)

    called = []
    monkeypatch.setattr(scribe, "run_scribe_agent",
                        lambda *a, **kw: called.append(a) or None)
    import sys
    sys.modules["tools.agents.scribe"] = scribe

    orchestrator.append_log(_entry())
    assert called == []
    written = _read_last(patched_log_env)
    assert "_diff" not in written
    assert "lesson" not in written
    assert "scribe_skipped" not in written
