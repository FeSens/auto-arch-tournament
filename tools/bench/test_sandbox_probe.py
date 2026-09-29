"""The pre-run sandbox probe (tools/bench/sandbox_probe.py) and the runner's
use of it (V2 incident 06: Claude's sandbox silently off)."""
import json
import subprocess

from tools.bench import runner
from tools.bench.sandbox_probe import judge

HOST = {"pidns": "pid:[4026531836]", "mntns": "mnt:[4026531832]"}
CONFINED = {"pidns": "pid:[4026532886]", "mntns": "mnt:[4026532885]",
            "network": "blocked", "account_home": "hidden"}


def test_judge_accepts_a_confined_command():
    assert judge(CONFINED, HOST, "claude") == []
    assert judge({**CONFINED, "account_home": "visible"}, HOST, "codex") == []


def test_judge_rejects_the_incident_06_shape():
    seen = {"pidns": HOST["pidns"], "mntns": HOST["mntns"], "network": "open",
            "account_home": "visible"}
    reasons = judge(seen, HOST, "claude")
    assert any("pidns is the host's" in r for r in reasons)
    assert any("mntns is the host's" in r for r in reasons)
    assert "network open" in reasons and "account home visible" in reasons


def test_judge_rejects_partial_and_missing_results():
    assert judge({}, HOST, "codex") == ["the agent did not run the probe command (no result file)"]
    assert judge({**CONFINED, "network": "open"}, HOST, "codex") == ["network open"]
    assert judge({k: v for k, v in CONFINED.items() if k != "mntns"}, HOST, "codex") == [
        "mntns not reported"]


def _fake_probe(monkeypatch, tmp_path, verdicts):
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        d = tmp_path / ".tmp" / "sandbox-probe"
        d.mkdir(parents=True, exist_ok=True)
        (d / "verdict.json").write_text(json.dumps(verdicts[len(calls) - 1]))
        return subprocess.CompletedProcess(cmd, 0, "", "")
    monkeypatch.setattr(runner.subprocess, "run", fake_run)
    return calls


def test_run_sandbox_probe_retries_only_when_the_agent_did_not_run_it(monkeypatch, tmp_path):
    no_run = {"ok": False, "reasons": ["the agent did not run the probe command (no result file)"]}
    calls = _fake_probe(monkeypatch, tmp_path, [no_run, {"ok": True, "reasons": []}])
    v = runner.run_sandbox_probe(tmp_path, {})
    assert v["ok"] and v["attempt"] == 2 and len(calls) == 2
    calls = _fake_probe(monkeypatch, tmp_path, [{"ok": False, "reasons": ["network open"]}, None])
    v = runner.run_sandbox_probe(tmp_path, {})
    assert not v["ok"] and v["attempt"] == 1 and len(calls) == 1
