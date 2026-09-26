"""Verifies run_pgroup() kills the entire process group on timeout.

The leaked-formal-tree pattern observed in the gpt-5.5 effort sweep:
bash → make -j10 → sby → yosys-smtbmc → bitwuzla. subprocess.run's
TimeoutExpired only kills the bash; descendants reparent to launchd
and keep solving SMT problems with nobody waiting on them. This test
reproduces the shape (parent bash → grandchild sleep) and asserts that
on timeout, the grandchild is also dead.
"""
import os
import subprocess
import time

import pytest

from tools.eval._subprocess import run_pgroup


def _proc_alive(pid: int) -> bool:
    """True if pid exists and isn't a zombie. On macOS, killed-then-orphaned
    grandchildren get reaped by launchd within a few hundred ms, so a poll
    is reliable as long as we give the kernel a beat to catch up."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # process exists, we just can't signal it


def test_run_pgroup_kills_grandchild_on_timeout(tmp_path):
    pid_file = tmp_path / "child.pid"
    script = tmp_path / "spawn.sh"
    script.write_text(
        "#!/bin/bash\n"
        f"bash -c 'echo $$ > {pid_file}; sleep 30' &\n"
        "wait\n"
    )
    script.chmod(0o755)

    with pytest.raises(subprocess.TimeoutExpired):
        run_pgroup(["bash", str(script)], timeout=1)

    # Grandchild must have recorded its pid before being killed.
    for _ in range(20):
        if pid_file.exists():
            break
        time.sleep(0.1)
    assert pid_file.exists(), "grandchild never ran"
    grandchild_pid = int(pid_file.read_text().strip())

    # Grandchild must be gone within a reasonable window after killpg.
    for _ in range(20):
        if not _proc_alive(grandchild_pid):
            break
        time.sleep(0.1)
    assert not _proc_alive(grandchild_pid), (
        f"grandchild pid {grandchild_pid} still alive after timeout — "
        "process group kill did not propagate"
    )


def test_run_pgroup_kills_grandchild_in_escaped_pgroup(tmp_path):
    """sby_core.py calls os.setpgrp() per task, so each leaf is in its own
    process group. The outer killpg can't reach them — only descendant-tree
    walking by PPID can. This is the actual leak we observed in production."""
    pid_file = tmp_path / "child.pid"
    helper = tmp_path / "escape.py"
    helper.write_text(
        "import os, sys, time\n"
        "os.setpgrp()  # leave the parent's process group, like sby does\n"
        f"open({str(pid_file)!r}, 'w').write(str(os.getpid()))\n"
        "time.sleep(30)\n"
    )
    script = tmp_path / "spawn.sh"
    script.write_text(
        "#!/bin/bash\n"
        f"python3 {helper} &\n"
        "wait\n"
    )
    script.chmod(0o755)

    with pytest.raises(subprocess.TimeoutExpired):
        run_pgroup(["bash", str(script)], timeout=1)

    for _ in range(20):
        if pid_file.exists():
            break
        time.sleep(0.1)
    assert pid_file.exists(), "escaped grandchild never ran"
    escaped_pid = int(pid_file.read_text().strip())

    for _ in range(20):
        if not _proc_alive(escaped_pid):
            break
        time.sleep(0.1)
    assert not _proc_alive(escaped_pid), (
        f"escaped grandchild pid {escaped_pid} still alive — descendant-tree "
        "walk did not reach processes in detached process groups"
    )


def test_run_pgroup_normal_completion_returns_completedprocess(tmp_path):
    result = run_pgroup(
        ["bash", "-c", "echo hi; exit 0"],
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == "hi"


def test_run_pgroup_propagates_nonzero_exit(tmp_path):
    result = run_pgroup(
        ["bash", "-c", "exit 7"], capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 7
