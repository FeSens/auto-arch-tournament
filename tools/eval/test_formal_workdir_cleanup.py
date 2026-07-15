"""Tests for the post-tally SBY work dir cleanup in tools/eval/formal.py.

formal/run_all.sh (READ ONLY, contract) names each run's work dir
`formal/riscv-formal/cores/<CORE_NAME>-<$$>` (bash's own PID) and only
reaps stale ones itself on the *next* invocation for the same CORE_NAME
(see the "Reap stale per-PID work dirs" block). A target that's only
formal-checked once per orchestrator iteration would otherwise leave one
SBY work dir (SMT traces, yosys IR, engine logs; can run 100+ MB) behind
per iteration for the life of a rep. formal.py cannot learn its bash
child's PID through run_pgroup's CompletedProcess return value, so
_cleanup_formal_workdir globs `cores/<target>-*` instead of an exact
path (documented fallback per task-7 brief Step 3) but only removes a
match whose PID suffix names a process that is no longer alive --
mirroring run_all.sh's own reaper -- so a concurrent invocation (e.g.
the agent self-checking via `bash formal/run_all.sh` mid-implementation
while the orchestrator's own eval is also in flight) is never touched.
"""
import os
import subprocess
import sys

from tools.eval.formal import _cleanup_formal_workdir


def _dead_pid() -> int:
    """A PID that is (almost certainly) not currently alive.

    Spawns and immediately waits on a short-lived child, so the returned
    PID is guaranteed to have existed and then exited -- no PID-reuse
    race with a still-running process.
    """
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    return p.pid


def test_removes_dead_pid_workdir(tmp_path):
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    workdir = cores / f"v1-{_dead_pid()}"
    workdir.mkdir(parents=True)
    (workdir / "checks.cfg").write_text("stub")

    _cleanup_formal_workdir(tmp_path, "v1")

    assert not workdir.exists()


def test_keeps_live_pid_workdir(tmp_path):
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    workdir = cores / f"v1-{os.getpid()}"
    workdir.mkdir(parents=True)

    _cleanup_formal_workdir(tmp_path, "v1")

    assert workdir.exists()


def test_env_flag_keeps_dead_pid_workdir(tmp_path, monkeypatch):
    monkeypatch.setenv("BENCH_KEEP_FORMAL_WORKDIR", "1")
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    workdir = cores / f"v1-{_dead_pid()}"
    workdir.mkdir(parents=True)

    _cleanup_formal_workdir(tmp_path, "v1")

    assert workdir.exists()


def test_target_none_is_a_no_op(tmp_path):
    # No cores/ dir at all -- must not raise.
    _cleanup_formal_workdir(tmp_path, None)


def test_only_matches_own_target_prefix(tmp_path):
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    pid = _dead_pid()
    v1_dir = cores / f"v1-{pid}"
    v2_dir = cores / f"v2-{pid}"
    v1_dir.mkdir(parents=True)
    v2_dir.mkdir(parents=True)

    _cleanup_formal_workdir(tmp_path, "v1")

    assert not v1_dir.exists()
    assert v2_dir.exists()


def test_non_pid_suffix_left_alone(tmp_path):
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    # Tracked upstream reference cores (nerv, picorv32, serv, VexRiscv)
    # never carry a numeric PID suffix; a name like this shouldn't match
    # our target's glob prefix logic into deleting something unintended.
    odd_dir = cores / "v1-not-a-pid"
    odd_dir.mkdir(parents=True)

    _cleanup_formal_workdir(tmp_path, "v1")

    assert odd_dir.exists()


def test_missing_cores_dir_is_a_no_op(tmp_path):
    # Nothing under formal/ at all yet -- must not raise.
    _cleanup_formal_workdir(tmp_path, "v1")
