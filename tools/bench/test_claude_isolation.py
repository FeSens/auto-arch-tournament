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
    (ctmp / "leftover_scratch.py").write_text("x")
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
    # Agents may run formal in their own copy; the eval's copy is read-only.
    assert fs["denyWrite"] == [str(clone.resolve() / ".tmp" / "riscv-formal-eval")]
    from tools.bench.runner import IS_MAC
    assert str(home) in fs["denyRead"]
    assert ("/private/tmp" if IS_MAC else "/tmp") in fs["denyRead"]
    # Other Claude sessions' temp dirs are denied; the rep's own are not.
    assert str(ctmp / "-Users-me-other-project") in fs["denyRead"]
    assert str(ctmp / "leftover_scratch.py") in fs["denyRead"]
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
    assert "do it" not in cmd and cmd.stdin == "do it"   # the prompt goes on stdin


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


def test_python_user_site_is_readable(tmp_path, monkeypatch):
    import tools.bench.runner as r
    site = tmp_path / "py" / "lib" / "python3.13" / "site-packages"
    site.mkdir(parents=True)
    monkeypatch.setattr(r, "_python_user_site", lambda: str(site))
    s, *_ = _settings(tmp_path)
    assert str(site) in s["sandbox"]["filesystem"]["allowRead"]


def test_tool_roots_never_open_home(tmp_path, monkeypatch):
    import tools.bench.runner as r
    home = tmp_path / "home"
    (home / ".local" / "bin").mkdir(parents=True)
    tc = tmp_path / "work" / "riscv" / ".toolchain" / "bin"
    tc.mkdir(parents=True)
    for d, name in ((home / ".local" / "bin", "sby"), (tc, "yosys")):
        (d / name).write_text("#!/bin/sh\n")
        (d / name).chmod(0o755)
    monkeypatch.setenv("PATH", f"{home / '.local' / 'bin'}:{tc}")
    roots = r._tool_read_roots(home)
    assert str(tc.parent) in roots
    assert str(home / ".local") not in roots and str(home) not in roots


def test_claude_parser_recovers_killed_sessions(tmp_path):
    def asst(sid, mid, inp, out):
        return json.dumps({"type": "assistant", "session_id": sid,
                           "message": {"id": mid, "usage": {"input_tokens": inp,
                               "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                               "output_tokens": out}}})
    lines = [asst("done", "m1", 5, 1),
             json.dumps({"type": "result", "session_id": "done", "uuid": "r1", "total_cost_usd": 1.0,
                         "modelUsage": {"m": {"inputTokens": 5, "outputTokens": 40}}}),
             asst("killed", "m2", 100, 3), asst("killed", "m2", 100, 3), asst("killed", "m3", 200, 4)]
    log = tmp_path / "a.log"
    log.write_text("\n".join(lines) + "\n")
    assert parse_claude_cost_from_log(log) == (305, 47, 1.0)


def test_eval_uses_harness_riscv_formal_copy(tmp_path):
    from tools.sandbox import take_snapshot, snapshot_changes, use_eval_riscv_formal
    root = tmp_path / "clone"
    agent_rf = root / "formal" / "riscv-formal"
    eval_rf = root / ".tmp" / "riscv-formal-eval"
    for rf in (agent_rf, eval_rf):
        (rf / "checks").mkdir(parents=True)
        (rf / "checks" / "genchecks.py").write_text("gen\n")
    wt = root / "wt"
    (wt / "formal").mkdir(parents=True)
    (wt / "formal" / "riscv-formal").symlink_to(agent_rf)
    before = take_snapshot(root)
    (eval_rf / "checks" / "genchecks.py").write_text("tampered\n")
    assert snapshot_changes(before, take_snapshot(root)) == [
        "riscv-formal-eval/checks/genchecks.py"]
    assert use_eval_riscv_formal(wt, root)
    assert (wt / "formal" / "riscv-formal").resolve() == eval_rf.resolve()


def test_env_under_agent_user(tmp_path, monkeypatch):
    """With HWE_AGENT_USER, agents get the agent account's home, the
    shared toolchain, and a Codex auth link into the agent's own login."""
    import getpass
    from pathlib import Path
    from tools.bench import runner
    monkeypatch.setenv("HWE_AGENT_USER", getpass.getuser())
    shared = tmp_path / "shared"
    for d in ("toolchain", "bin", "venv", "homes", "tmp"):
        (shared / d).mkdir(parents=True)
    monkeypatch.setattr(runner, "AGENT_SHARED", shared)
    clone = tmp_path / "clone"
    clone.mkdir()
    claude = JobSpec(model=ModelEntry(name="opus", provider="claude",
                                      model="claude-opus-5-5", oauth=True), rep=1)
    env = make_env_for_job(claude, clone, {})
    assert env["HWE_AGENT_PATH"].startswith(f"{shared}/bin:{shared}/venv/bin:")
    fs = json.loads(env["CLAUDE_BENCH_SETTINGS"])["sandbox"]["filesystem"]
    assert str(shared / "toolchain") in fs["allowRead"]
    # A fresh HOME per run; the account's real home (its Codex login) is
    # unreadable to Claude's sandbox too.
    assert env["HWE_AGENT_HOME"] == str(shared / "homes" / "opus-rep1")
    assert Path(env["HWE_AGENT_HOME"]).is_dir()
    assert env["HWE_AGENT_HOME"] in fs["denyRead"]
    assert str(Path.home()) in fs["denyRead"]
    deny = json.loads(env["CLAUDE_BENCH_SETTINGS"])["permissions"]["deny"]
    assert {"WebFetch", "WebSearch", "ToolSearch", "RemoteTrigger"} <= set(deny)
    assert env["HWE_AGENT_USER"] == getpass.getuser()
    # Fail closed, and the run's short temp base (incident 06) is writable.
    sb = json.loads(env["CLAUDE_BENCH_SETTINGS"])["sandbox"]
    assert sb["failIfUnavailable"] is True and sb["allowUnsandboxedCommands"] is False
    assert env["HWE_AGENT_TMP"].startswith(str(shared / "tmp") + "/")
    assert Path(env["HWE_AGENT_TMP"]).is_dir()
    assert env["HWE_AGENT_TMP"] in fs["allowWrite"] and env["HWE_AGENT_TMP"] in fs["allowRead"]
    codex = JobSpec(model=ModelEntry(name="gpt", provider="codex",
                                     model="gpt-6-sol", oauth=True), rep=1)
    env = make_env_for_job(codex, clone, {})
    link = Path(env["CODEX_HOME"]) / "auth.json"
    assert link.is_symlink()
    assert str(link.readlink()) == str(Path.home() / ".codex" / "auth.json")
    cfg = (Path(env["CODEX_HOME"]) / "config.toml").read_text()
    assert 'web_search = "disabled"' in cfg
    for off in ("memories", "apps", "plugins", "remote_plugin", "browser_use", "computer_use",
                "daemon_auto_start", "write_stdin_approval"):
        assert f"\n{off} = false\n" in cfg, off


def test_claude_token_only_in_claude_jobs(tmp_path, monkeypatch):
    """V2 incident 05: the Claude login token went into every job's
    environment and from there to the Codex agents too."""
    import getpass
    from tools.bench import runner
    monkeypatch.setenv("HWE_AGENT_USER", getpass.getuser())
    shared = tmp_path / "shared"
    for d in ("toolchain", "bin", "venv", "homes", "tmp"):
        (shared / d).mkdir(parents=True)
    monkeypatch.setattr(runner, "AGENT_SHARED", shared)
    clone = tmp_path / "clone"
    clone.mkdir()
    keys = {"CLAUDE_CODE_OAUTH_TOKEN": "tok-from-file"}
    claude = JobSpec(model=ModelEntry(name="opus", provider="claude",
                                      model="claude-opus-5-5", oauth=True), rep=1)
    codex = JobSpec(model=ModelEntry(name="gpt", provider="codex",
                                     model="gpt-6-sol", oauth=True), rep=1)
    assert make_env_for_job(claude, clone, keys)["CLAUDE_CODE_OAUTH_TOKEN"] == "tok-from-file"
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in make_env_for_job(codex, clone, keys)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "tok-exported")
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in make_env_for_job(codex, clone, {})
    assert make_env_for_job(claude, clone, {})["CLAUDE_CODE_OAUTH_TOKEN"] == "tok-exported"


def test_model_cli_dir_goes_first_on_that_models_path_only(tmp_path, monkeypatch):
    """V2 amendment 11: GPT-6.1 Sol needs Codex 0.159.0, the pinned 0.156.1
    is refused for it; Luna stays on the pinned CLI."""
    import getpass
    from pathlib import Path
    from tools.bench import runner
    monkeypatch.setenv("HWE_AGENT_USER", getpass.getuser())
    shared = tmp_path / "shared"
    for d in ("toolchain", "bin", "venv", "homes", "tmp", "cli/codex-new"):
        (shared / d).mkdir(parents=True)
    (shared / "bin" / "codex.version.json").write_text('{"version": "0.156.1"}')
    (shared / "bin" / "claude.version").write_text("2.1.283")
    (shared / "cli/codex-new" / "codex.version.json").write_text('{"version": "0.159.0"}')
    monkeypatch.setattr(runner, "AGENT_SHARED", shared)
    clone = tmp_path / "clone"
    clone.mkdir()
    new = ModelEntry(name="sol61", provider="codex", model="gpt-6.1-sol", oauth=True,
                     cli_dir="cli/codex-new")
    old = ModelEntry(name="luna", provider="codex", model="gpt-6-luna", oauth=True)
    env = make_env_for_job(JobSpec(model=new, rep=1), clone, {})
    assert env["HWE_AGENT_PATH"].startswith(f"{shared}/cli/codex-new:{shared}/bin:")
    env = make_env_for_job(JobSpec(model=old, rep=1), clone, {})
    assert env["HWE_AGENT_PATH"].startswith(f"{shared}/bin:")
    assert "cli/" not in env["HWE_AGENT_PATH"]
    agent = runner.agent_user()
    assert agent.cli_versions(runner.model_cli_dir(new, agent)) == {
        "claude_cli": "2.1.283", "codex_cli": "0.159.0"}
    assert agent.cli_versions(runner.model_cli_dir(old, agent))["codex_cli"] == "0.156.1"
    # A CLI dir without the provider's executable would run the pinned CLI
    # instead: refused before any run starts.
    assert runner.cli_dir_problems([new, old]) == [
        f"sol61: no executable codex in cli_dir {shared}/cli/codex-new"]
    exe = shared / "cli/codex-new" / "codex"
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    assert runner.cli_dir_problems([new, old]) == []
    cfg = tmp_path / "models.yaml"
    cfg.write_text("models:\n  - {name: a, model: m, provider: codex, cli_dir: cli/x}\n"
                   "  - {name: b, model: m, provider: codex}\n")
    assert [m.cli_dir for m in runner.load_models(cfg)] == ["cli/x", None]
