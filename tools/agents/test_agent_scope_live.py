"""Live checks of the agent launch path on the run host: the root helper
(/usr/local/sbin/hwe-agent-scope, research/v2/scripts/setup_server.sh 6d)
and a real agent account. Opt-in (HWE_LIVE_AGENT_TESTS=1): they start
processes in an agent account's CPU slice, which must not happen while a
campaign uses that account.

V2 incident 05: an agent's backgrounded formal solvers outlived the agent,
and the Claude login token reached every agent on its command line."""
import os
import subprocess
import time
import uuid
from pathlib import Path

import pytest

from tools.agents._runtime import AGENT_SCOPE, as_agent_user
from tools.eval._subprocess import kill_process_tree

ACCOUNT = os.environ.get("HWE_LIVE_AGENT_USER", "hwebench")
CLONES = Path("/srv/hwebench/clones")

pytestmark = pytest.mark.skipif(
    os.environ.get("HWE_LIVE_AGENT_TESTS") != "1" or not Path(AGENT_SCOPE).exists(),
    reason="live agent-account tests are opt-in (HWE_LIVE_AGENT_TESTS=1) on the run host")

# The incident's shape: a process that ignores every catchable signal, in a
# session of its own, already reparented away from the command (double
# fork), so no process-tree walk from the command finds it.
STUBBORN = "(setsid sh -c 'trap \"\" TERM HUP INT; exec sleep 300' >/dev/null 2>&1 </dev/null &);"


def _gone(pid: int, within: float = 5.0) -> bool:
    end = time.time() + within
    while time.time() < end:
        if not Path(f"/proc/{pid}").exists():
            return True
        time.sleep(0.1)
    return False


def _sweep(pid: int) -> None:
    subprocess.run(["sudo", "-n", "-u", ACCOUNT, "/bin/kill", "-KILL", str(pid)], capture_output=True)


def test_what_a_command_leaves_behind_dies_with_it():
    r = subprocess.run(["sudo", "-n", AGENT_SCOPE, ACCOUNT, "/bin/sh", "-c",
                        f"{STUBBORN} sleep 0.3; pgrep -u {ACCOUNT} -n -x sleep; exit 3"],
                       capture_output=True, text=True, timeout=60)
    assert r.returncode == 3                     # the command's own status
    pid = int(r.stdout.split()[-1])
    try:
        assert _gone(pid)
    finally:
        _sweep(pid)


def test_the_harness_timeout_path_reaps_the_scope(monkeypatch):
    """tools/agents/_runtime.py kills a timed-out agent with
    kill_process_tree; what the agent detached must die too."""
    monkeypatch.setenv("HWE_AGENT_USER", ACCOUNT)       # as in the orchestrator
    proc = subprocess.Popen(["sudo", "-n", AGENT_SCOPE, ACCOUNT, "/bin/sh", "-c",
                             f"{STUBBORN} sleep 0.3; pgrep -u {ACCOUNT} -n -x sleep; exec sleep 600"],
                            stdout=subprocess.PIPE, text=True)
    pid = int(proc.stdout.readline())
    try:
        assert Path(f"/proc/{pid}").exists()
        kill_process_tree(proc.pid)
        proc.wait(timeout=30)
        assert _gone(pid)
    finally:
        _sweep(pid)


@pytest.fixture
def agent_dir():
    """A directory shaped like a clone's: inside the clone base, with an
    ACL (and default ACL) for the account."""
    d = CLONES / f".live-test-{uuid.uuid4().hex[:8]}"
    d.mkdir()
    subprocess.run(["setfacl", "-m", f"u:{ACCOUNT}:rwx,d:u:{ACCOUNT}:rwx,d:u:{os.getuid()}:rwx",
                    str(d)], check=True)
    try:
        yield d
    finally:
        subprocess.run(["sudo", "-n", "-u", ACCOUNT, "/bin/rm", "-rf", str(d)], capture_output=True)
        subprocess.run(["rm", "-rf", str(d)], capture_output=True)


def _env(provider: str) -> dict:
    return {"HWE_AGENT_USER": ACCOUNT, "HWE_AGENT_HOME": "/nonexistent",
            "HWE_AGENT_PATH": "/usr/bin:/bin", "AGENT_PROVIDER": provider,
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-live-test-'\"$x"}


def test_only_the_claude_agent_gets_the_claude_token(agent_dir):
    for provider, want in (("claude", "sk-ant-live-test-'\"$x\n"), ("codex", "")):
        env = _env(provider)
        cmd = as_agent_user(["/usr/bin/printenv", "CLAUDE_CODE_OAUTH_TOKEN"], env, secrets_dir=agent_dir)
        assert not any("sk-ant" in a for a in cmd)
        r = subprocess.run(cmd, cwd=agent_dir, capture_output=True, text=True, timeout=60)
        assert r.stdout == want, (provider, r.stderr)
        assert [p.name for p in agent_dir.iterdir()] == []    # the credentials file is gone
