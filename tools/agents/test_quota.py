import datetime as dt
import json
import subprocess

import pytest

from tools.agents import quota

CODEX_LIMIT = ('{"type":"error","message":"You\'ve hit your usage limit. Visit '
               'https://chatgpt.com/codex/settings/usage to purchase more credits or try again '
               'at Sep 12th, 2026 10:21 AM."}')


def test_codex_weekly_limit_from_v1_astra_log():
    kind, reset = quota.classify([CODEX_LIMIT])
    assert kind == "quota"
    assert reset == dt.datetime(2026, 9, 12, 10, 21)


def test_agent_prose_about_rate_limits_is_ignored():
    prose = json.dumps({"type": "item.completed", "item": {
        "text": "The bus hits its rate limit when usage limit is reached (429)"}})
    assert quota.classify([prose]) == (None, None)


def test_claude_error_result_and_epoch_reset():
    ev = json.dumps({"type": "result", "is_error": True,
                     "result": "Claude AI usage limit reached|1790000000"})
    kind, reset = quota.classify([ev])
    assert kind == "quota" and reset == dt.datetime.fromtimestamp(1790000000)


def test_overload_is_transient():
    ev = json.dumps({"type": "result", "is_error": True, "result": "API Error: 529 overloaded"})
    assert quota.classify([ev]) == ("transient", None)


def test_wait_until_stated_reset_plus_slack():
    now = dt.datetime(2026, 9, 12, 10, 0)
    assert quota.wait_seconds("quota", dt.datetime(2026, 9, 12, 10, 21), now) == 21 * 60 + quota.RESET_SLACK_SEC
    assert quota.wait_seconds("quota", None, now) == quota.POLL_SEC


def test_attempt_reruns_from_scratch_after_limit(tmp_path):
    log = tmp_path / "agent.log"
    calls, resets, slept = [], [], []

    def run(mode):
        calls.append(mode)
        with log.open(mode) as f:
            f.write((CODEX_LIMIT if len(calls) == 1 else '{"type":"turn.completed"}') + "\n")
        return (1 if len(calls) == 1 else 0), False

    rc, timed_out = quota.run_with_quota_wait(
        run, log, reset_attempt=lambda: resets.append(1), sleep=slept.append)
    assert (rc, timed_out) == (0, False)
    assert calls == ["w", "a"] and resets == [1] and len(slept) == 1
    events = [json.loads(l) for l in log.read_text().splitlines() if "quota_pause" in l]
    assert events and events[0]["kind"] == "quota"


def test_timeout_is_never_treated_as_quota(tmp_path):
    log = tmp_path / "agent.log"

    def run(mode):
        log.write_text(CODEX_LIMIT + "\n")
        return -9, True

    assert quota.run_with_quota_wait(run, log, sleep=lambda s: None) == (-9, True)


def test_agent_user_wrapper_drops_operator_env():
    from tools.agents._runtime import agent_launch_prefix, as_agent_user
    env = {"HWE_AGENT_USER": "hwebench", "HWE_AGENT_HOME": "/Users/hwebench",
           "HWE_AGENT_PATH": "/Users/Shared/hwebench/bin:/usr/bin",
           "HWE_AGENT_PYTHONUSERBASE": "/Users/Shared/hwebench/local",
           "HOME": "/Users/op", "SECRET_TOKEN": "x", "CODEX_HOME": "/c/.codex-home",
           "AGENT_PROVIDER": "codex", "TMPDIR": "/c/.tmp",
           "HARNESS_EVAL_SLOTS": "3", "HARNESS_EVAL_LOCK_DIR": "/Users/op/.slots"}
    cmd = as_agent_user(["codex", "exec", "hi"], env)
    assert cmd[:9] == [*agent_launch_prefix("hwebench"), "/usr/bin/nice", "-n", "10",
                       "/usr/bin/env", "-i"]
    assert cmd[-3:] == ["codex", "exec", "hi"]
    assigns = cmd[cmd.index("-i") + 1:cmd.index("/bin/sh")]
    assert not any(a.startswith("HARNESS_EVAL") for a in assigns)
    assert "HOME=/Users/hwebench" in assigns and "CODEX_HOME=/c/.codex-home" in assigns
    assert "PATH=/Users/Shared/hwebench/bin:/usr/bin" in assigns
    assert not any(a.startswith("SECRET_TOKEN=") or a == "HOME=/Users/op" for a in assigns)
    assert as_agent_user(["codex"], {"HOME": "/x"}) == ["codex"]


def _agent_env(provider, **extra):
    return {"HWE_AGENT_USER": "hwebench", "HWE_AGENT_HOME": "/srv/hwebench/homes/r",
            "HWE_AGENT_PATH": "/usr/bin:/bin", "AGENT_PROVIDER": provider,
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-it's a \"secret\" $HOME\nx", **extra}


def test_agent_credentials_never_go_on_the_command_line(tmp_path):
    """V2 incident 05: the Claude token reached every agent, Codex ones
    included, as an `env` argument that sudo and systemd logged."""
    from tools.agents._runtime import as_agent_user
    token = _agent_env("claude")["CLAUDE_CODE_OAUTH_TOKEN"]
    codex = as_agent_user(["codex", "exec", "hi"], _agent_env("codex"), secrets_dir=tmp_path)
    assert not any("sk-ant" in a for a in codex)
    assert list(tmp_path.iterdir()) == []            # nothing for Codex at all
    claude = as_agent_user(["claude", "-p", "hi"], _agent_env("claude"), secrets_dir=tmp_path)
    assert not any("sk-ant" in a for a in claude)
    (env_file,) = tmp_path.iterdir()
    assert env_file.name.startswith(".agent-env-") and str(env_file) in claude
    assert oct(env_file.stat().st_mode & 0o777) == oct(0o640 & ~_umask())
    # The launch wrapper exports it to the agent CLI and deletes the file.
    wrapper = claude[claude.index("/bin/sh"):]
    assert wrapper[-3:] == ["claude", "-p", "hi"]
    probe = [*wrapper[:-3], "/usr/bin/printenv", "CLAUDE_CODE_OAUTH_TOKEN"]
    r = subprocess.run(probe, capture_output=True, text=True)
    assert r.returncode == 0 and r.stdout == token + "\n"
    assert not env_file.exists()
    with pytest.raises(ValueError):
        as_agent_user(["claude"], _agent_env("claude"))


def _umask():
    import os
    m = os.umask(0)
    os.umask(m)
    return m


def test_agent_launch_goes_through_the_cpu_slice_helper_on_linux():
    from tools.agents._runtime import AGENT_SCOPE, agent_launch_prefix
    assert agent_launch_prefix("hwebench2", "linux") == ["sudo", "-n", AGENT_SCOPE, "hwebench2"]
    assert agent_launch_prefix("hwebench2", "darwin") == ["sudo", "-n", "-u", "hwebench2"]


def test_each_agent_invocation_gets_a_private_tmpdir(tmp_path, monkeypatch):
    """Concurrent agents of a run must not share TMPDIR (smoke10: a sibling
    overwrote an agent's logs in the run-wide <clone>/.tmp)."""
    import threading
    from pathlib import Path
    from tools.agents import _runtime
    monkeypatch.delenv("HWE_AGENT_USER", raising=False)
    monkeypatch.setenv("TMPDIR", str(tmp_path / "run-wide"))
    seen = []
    def one(i):
        ws = tmp_path / f"ws{i}"
        ws.mkdir()
        out = ws / "tmpdir.txt"
        _runtime.run_agent_streaming(
            ["/bin/sh", "-c", f'echo "$TMPDIR" > {out}; touch "$TMPDIR/scratch.log"; sleep 0.3'],
            cwd=str(ws), log_path=ws / "agent.log", timeout_sec=30, provider="claude")
        seen.append((ws, Path(out.read_text().strip())))
    threads = [threading.Thread(target=one, args=(i,)) for i in range(3)]
    for t in threads: t.start()
    for t in threads: t.join()
    dirs = [d for _, d in seen]
    assert len(set(dirs)) == 3
    for ws, d in seen:
        assert d.parent == ws.resolve() / ".tmp" and d.name.startswith("agent-")
        assert not d.exists()          # removed when the agent exits
