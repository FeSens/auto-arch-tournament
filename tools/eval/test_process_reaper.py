"""Stopping the orchestrator / runner must not orphan its subprocess trees."""
import os
import signal
import subprocess
import sys
import textwrap
import time

from tools.eval._subprocess import kill_process_tree


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie still answers kill(0); ask ps for its state.
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                        capture_output=True, text=True).stdout.strip()
    return bool(st) and not st.startswith("Z")


def _wait_dead(pid: int, timeout: float = 5.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if not _alive(pid):
            return True
        time.sleep(0.05)
    return False


def test_kill_process_tree_kills_setsid_grandchild():
    # bash -> (own session) sleep: the shape run_pgroup / sby produce.
    parent = subprocess.Popen(
        [sys.executable, "-c", textwrap.dedent("""
            import subprocess, sys, time
            c = subprocess.Popen(["sleep", "60"], start_new_session=True)
            print(c.pid, flush=True)
            time.sleep(60)
        """)],
        stdout=subprocess.PIPE, text=True,
    )
    grandchild = int(parent.stdout.readline())
    kill_process_tree(parent.pid)
    parent.wait(timeout=5)
    assert _wait_dead(grandchild)


def test_reaper_kills_descendants_on_sigterm_and_exits():
    proc = subprocess.Popen(
        [sys.executable, "-c", textwrap.dedent("""
            import subprocess, time
            from tools.eval._subprocess import install_tree_reaper
            install_tree_reaper()
            c = subprocess.Popen(["sleep", "60"], start_new_session=True)
            print(c.pid, flush=True)
            time.sleep(60)
        """)],
        stdout=subprocess.PIPE, text=True, cwd=os.getcwd(),
        env={**os.environ, "PYTHONPATH": os.getcwd()},
    )
    grandchild = int(proc.stdout.readline())
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 128 + signal.SIGTERM
    assert _wait_dead(grandchild)
