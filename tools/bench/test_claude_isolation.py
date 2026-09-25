"""Bench Claude Code agents run isolated from the operator's setup, and
their transcripts and tokens are collected."""
import json
import re

from tools.agents import _runtime
from tools.agents._runtime import archive_agent_log, build_agent_cmd
from tools.bench.runner import (
    JobSpec,
    ModelEntry,
    claude_instruction_ancestors,
    claude_isolation_settings,
    make_env_for_job,
)
from tools.bench.telemetry import collect_agent_logs, parse_claude_cost_from_log
from tools.bench.transcript import compact_line


def _settings(tmp_path):
    clone = tmp_path / "runs" / "opus-rep1"
    clone.mkdir(parents=True)
    ctmp = tmp_path / "claude-501"
    own = ctmp / re.sub(r"[^A-Za-z0-9]", "-", str(clone.resolve()))
    for d in (ctmp / "-Users-me-other-project", own, ctmp / (own.name + "-cores-bench-worktrees-x")):
        d.mkdir(parents=True)
    home = tmp_path / "home"
    home.mkdir()
    s = claude_isolation_settings(clone, uid=501, home=home, claude_tmp=ctmp)
    return s, clone, home, ctmp, own


def test_settings_disable_operator_setup(tmp_path):
    s, *_ = _settings(tmp_path)
    assert s["disableAllHooks"] and s["disableClaudeAiConnectors"]
    assert s["autoMemoryEnabled"] is False
    assert {"WebFetch", "WebSearch"} <= set(s["permissions"]["deny"])


def test_sandbox_confines_bash_to_clone(tmp_path):
    s, clone, home, ctmp, own = _settings(tmp_path)
    sb = s["sandbox"]
    assert sb["enabled"] and sb["allowUnsandboxedCommands"] is False
    assert sb["network"]["allowedDomains"] == []
    fs = sb["filesystem"]
    assert fs["allowWrite"] == [str(clone.resolve())]
    assert str(home) in fs["denyRead"] and "/private/tmp" in fs["denyRead"]
    # Other Claude sessions' temp dirs are denied; the rep's own are not.
    assert str(ctmp / "-Users-me-other-project") in fs["denyRead"]
    assert not any(d.startswith(str(own)) for d in fs["denyRead"])
    assert str(ctmp) in fs["allowRead"] and str(clone.resolve()) in fs["allowRead"]


def test_instruction_ancestors_detected(tmp_path):
    (tmp_path / "CLAUDE.md").write_text("repo contract")
    clone = tmp_path / ".claude" / "bench-runs" / "x"
    clone.mkdir(parents=True)
    assert claude_instruction_ancestors(clone) == [tmp_path / "CLAUDE.md"]
    assert claude_instruction_ancestors(tmp_path / "elsewhere") == [tmp_path / "CLAUDE.md"]


def test_env_for_claude_job(tmp_path):
    clone = tmp_path / "clone"
    clone.mkdir()
    job = JobSpec(model=ModelEntry(name="opus", provider="claude",
                                   model="claude-opus-5-5", variant="xhigh",
                                   oauth=True), rep=1)
    env = make_env_for_job(job, clone, {})
    assert env["AGENT_PROVIDER"] == "claude"
    assert env["ANTHROPIC_MODEL"] == "claude-opus-5-5"
    assert env["CLAUDE_EFFORT"] == "xhigh"
    assert env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1"
    assert json.loads(env["CLAUDE_BENCH_SETTINGS"])["sandbox"]["enabled"]


def test_cmd_isolated_when_settings_present(monkeypatch):
    monkeypatch.setenv("CLAUDE_BENCH_SETTINGS", '{"sandbox":{"enabled":true}}')
    monkeypatch.setenv("CLAUDE_EFFORT", "xhigh")
    cmd = build_agent_cmd("do it", cwd=".", provider="claude")
    assert "--dangerously-skip-permissions" not in cmd
    assert cmd[cmd.index("--setting-sources") + 1] == ""
    assert "--strict-mcp-config" in cmd
    assert cmd[cmd.index("--permission-mode") + 1] == "acceptEdits"
    assert cmd[cmd.index("--settings") + 1] == '{"sandbox":{"enabled":true}}'
    assert cmd[cmd.index("--effort") + 1] == "xhigh"
    for tool in ("WebFetch", "WebSearch", "SendMessage", "PushNotification"):
        assert tool in cmd
    assert cmd[2] == "do it"


def test_cmd_legacy_without_settings(monkeypatch):
    monkeypatch.delenv("CLAUDE_BENCH_SETTINGS", raising=False)
    cmd = build_agent_cmd("do it", cwd=".", provider="claude")
    assert "--dangerously-skip-permissions" in cmd


def _result(uid, cost, inp=10, cr=100, cc=50, out=7):
    return json.dumps({"type": "result", "uuid": uid, "total_cost_usd": cost,
                       "modelUsage": {"m": {"inputTokens": inp, "cacheReadInputTokens": cr,
                                            "cacheCreationInputTokens": cc, "outputTokens": out}}})


def test_claude_cost_parser_sums_and_dedups(tmp_path):
    log = tmp_path / "a.log"
    log.write_text("\n".join([_result("u1", 0.5), '{"type":"assistant"}',
                              _result("u2", 0.25), _result("u1", 0.5)]) + "\n")
    assert parse_claude_cost_from_log(log) == (320, 14, 0.75)


def test_archived_logs_are_collected(tmp_path, monkeypatch):
    clone = tmp_path / "clone"
    wt = clone / "cores" / "bench" / "worktrees" / "hyp-r1s0"
    wt.mkdir(parents=True)
    (wt / ".agent.log").write_text("impl transcript\n")
    archive_agent_log(wt / ".agent.log", "impl.hyp-r1s0", repo=clone)
    archive_agent_log(wt / ".agent.log", "impl.hyp-r1s0", repo=clone)  # retry appends
    (wt / ".agent.log").unlink()                                          # worktree removed
    out = collect_agent_logs(clone).read_text()
    assert out.count("impl transcript") == 2


def test_claude_tool_results_are_compacted():
    big = "x" * 20000
    ev = {"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t", "content": big}]},
          "tool_use_result": {"stdout": big, "stderr": ""}}
    out = json.loads(compact_line(json.dumps(ev)))
    assert len(out["message"]["content"][0]["content"]) < 5000
    assert len(out["tool_use_result"]["stdout"]) < 5000
    prompt = {"type": "user", "message": {"content": [{"type": "text", "text": big}]}}
    assert json.loads(compact_line(json.dumps(prompt)))["message"]["content"][0]["text"] == big


def test_disallowed_tools_cover_outside_reach():
    assert {"SendMessage", "ListAgents", "RemoteTrigger", "Workflow"} <= set(
        _runtime.CLAUDE_BENCH_DISALLOWED_TOOLS)
