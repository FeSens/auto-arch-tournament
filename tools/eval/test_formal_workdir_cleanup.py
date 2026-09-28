"""Tests for the riscv-formal work dirs: tools/eval/formal.py's post-tally
cleanup and formal/run_all.sh's naming and reaping.

The K concurrent agents of a run share one riscv-formal checkout (their
worktrees symlink it). run_all.sh used to name its work dir
"<CORE_NAME>-$$" and reap dirs whose PID failed `kill -0`; inside an agent
sandbox's PID namespace $$ is 2 or 3 for every agent and every outside PID
looks dead, so siblings wrote into one dir and deleted each other's live
checks (V2 incident 03). Now each run gets a mktemp name, holds a flock on
<dir>/.owner.lock while it runs, and the reaper removes only dirs whose
lock is free and over 10 minutes old; the harness pins its dir name with
FORMAL_WORK_ID and removes exactly that dir.
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

from tools.eval import formal
from tools.eval.formal import _cleanup_formal_workdir

REPO = Path(__file__).resolve().parents[2]


# ---- formal.py: exact cleanup ------------------------------------------

def test_removes_exactly_its_own_workdir(tmp_path):
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    own = cores / "bench-habc123"
    sibling = cores / "bench-wQ3xZ9aa"     # a live agent self-check
    legacy = cores / "bench-2"
    for d in (own, sibling, legacy):
        d.mkdir(parents=True)
        (d / "checks.cfg").write_text("stub")

    _cleanup_formal_workdir(tmp_path, "bench", "habc123")

    assert not own.exists()
    assert sibling.exists() and legacy.exists()


def test_env_flag_keeps_workdir(tmp_path, monkeypatch):
    monkeypatch.setenv("BENCH_KEEP_FORMAL_WORKDIR", "1")
    own = tmp_path / "formal" / "riscv-formal" / "cores" / "bench-habc123"
    own.mkdir(parents=True)
    _cleanup_formal_workdir(tmp_path, "bench", "habc123")
    assert own.exists()


def test_no_core_name_is_a_no_op(tmp_path):
    _cleanup_formal_workdir(tmp_path, None, "habc123")


def test_run_formal_pins_and_removes_its_workdir(tmp_path, monkeypatch):
    (tmp_path / "formal").mkdir()
    (tmp_path / "formal" / "run_all.sh").write_text("")
    (tmp_path / "cores" / "bench").mkdir(parents=True)
    (tmp_path / "cores" / "bench" / "core.yaml").write_text("nret: 1\n")
    cores = tmp_path / "formal" / "riscv-formal" / "cores"
    sibling = cores / "bench-wSibling1"
    sibling.mkdir(parents=True)
    seen = {}

    def fake_run(cmd, **kw):
        wid = kw["env"]["FORMAL_WORK_ID"]
        seen["id"] = wid
        (cores / f"bench-{wid}").mkdir()
        return subprocess.CompletedProcess(cmd, 0, "Formal: 60 passed, 0 failed\n", "")

    monkeypatch.setattr(formal, "run_pgroup", fake_run)
    res = formal.run_formal(str(tmp_path), "bench")
    assert res["passed"]
    assert seen["id"].startswith("h") and seen["id"].isalnum()
    assert not (cores / f"bench-{seen['id']}").exists()
    assert sibling.exists()


# ---- run_all.sh: naming and reaping (stub framework, no SBY) -----------

GENCHECKS = """\
import os, pathlib
p = pathlib.Path("checks"); p.mkdir()
(p / "makefile").write_text("all:\\n\\t@sleep $${STUB_SLEEP:-0}\\n")
(p / "x.sby").write_text("")
(p / "x").mkdir(); (p / "x" / "logfile.txt").write_text("DONE (PASS")
pathlib.Path(os.environ["STUB_OUT"], os.path.basename(os.getcwd())).write_text("")
"""


@pytest.fixture
def stub_root(tmp_path):
    if not shutil.which("flock"):
        pytest.skip("flock(1) not available")
    root = tmp_path / "root"
    (root / "formal" / "riscv-formal" / "checks").mkdir(parents=True)
    (root / "formal" / "riscv-formal" / "cores").mkdir()
    shutil.copy(REPO / "formal" / "run_all.sh", root / "formal" / "run_all.sh")
    (root / "formal" / "wrapper.sv").write_text("module w; endmodule\n")
    (root / "formal" / "checks.cfg").write_text("[options]\n[verilog-files]\n")
    (root / "formal" / "riscv-formal" / "checks" / "genchecks.py").write_text(GENCHECKS)
    (root / "cores" / "t" / "rtl").mkdir(parents=True)
    (root / "cores" / "t" / "rtl" / "a.sv").write_text("module a; endmodule\n")
    (tmp_path / "out").mkdir()
    return root


def _env(root, **extra):
    return {**os.environ, "RTL_DIR": "cores/t/rtl", "CORE_NAME": "t",
            "STUB_OUT": str(root.parent / "out"), "JOBS": "1", **extra}


def _run(root, *prefix, **extra):
    return subprocess.run([*prefix, "bash", "formal/run_all.sh"], cwd=root,
                          env=_env(root, **extra), capture_output=True, text=True)


def _cores(root):
    return root / "formal" / "riscv-formal" / "cores"


def test_run_all_names_are_unique_and_letter_led(stub_root):
    for _ in range(2):
        r = _run(stub_root)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "Formal: 1 passed, 0 failed" in r.stdout
    names = sorted(p.name for p in (stub_root.parent / "out").iterdir())
    assert len(names) == 2 and names[0] != names[1]
    for n in names:
        suffix = n.split("-", 1)[1]
        assert suffix[0] == "w" and suffix.isalnum(), n
        assert (stub_root / "formal" / f"last_run-{suffix}.log").is_file()


def test_run_all_workdir_follows_umask(stub_root):
    """mktemp -d would make it 0700; agents run at umask 007 and the harness
    must still be able to read and remove what they leave."""
    env_umask = ["bash", "-c", "umask 007; exec bash formal/run_all.sh"]
    r = subprocess.run(env_umask, cwd=stub_root, env=_env(stub_root), capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    (d,) = [p for p in _cores(stub_root).iterdir() if p.name.startswith("t-w")]
    assert oct(d.stat().st_mode & 0o777) == oct(0o770)


def test_run_all_honors_and_validates_formal_work_id(stub_root):
    r = _run(stub_root, FORMAL_WORK_ID="hdeadbeef")
    assert r.returncode == 0, r.stdout + r.stderr
    assert (_cores(stub_root) / "t-hdeadbeef").is_dir()
    assert _run(stub_root, FORMAL_WORK_ID="hdeadbeef").returncode != 0   # no reuse
    assert _run(stub_root, FORMAL_WORK_ID="123").returncode != 0         # letter first
    assert _run(stub_root, FORMAL_WORK_ID="h-x/..").returncode != 0


def _old(path, minutes):
    t = time.time() - minutes * 60
    os.utime(path, (t, t))


def test_run_all_reaps_only_finished_runs(stub_root):
    cores = _cores(stub_root)
    stale, held, nolock, fresh = (cores / f"t-w{n}" for n in ("Stale001", "Held0001", "NoLock01", "Fresh001"))
    for d in (stale, held, nolock, fresh):
        d.mkdir()
    for d in (stale, held, fresh):
        (d / ".owner.lock").write_text("")
    _old(stale / ".owner.lock", 30)
    _old(held / ".owner.lock", 30)
    other_core = cores / "u-wStale001"
    other_core.mkdir()
    (other_core / ".owner.lock").write_text("")
    _old(other_core / ".owner.lock", 30)
    (stub_root / "formal" / "last_run-wStale001.log").write_text("x")
    holder = subprocess.Popen(["flock", str(held / ".owner.lock"), "sleep", "30"])
    try:
        time.sleep(0.5)
        r = _run(stub_root)
        assert r.returncode == 0, r.stdout + r.stderr
    finally:
        holder.kill()
        holder.wait()
    assert not stale.exists()
    assert not (stub_root / "formal" / "last_run-wStale001.log").exists()
    assert held.exists() and nolock.exists() and fresh.exists() and other_core.exists()


def _can_unshare():
    return shutil.which("unshare") and subprocess.run(
        ["unshare", "-r", "-p", "-f", "true"], capture_output=True).returncode == 0


@pytest.mark.skipif(not _can_unshare(), reason="unprivileged PID namespaces unavailable")
def test_concurrent_runs_in_separate_pid_namespaces_do_not_collide(stub_root):
    """The incident-03 shape: two sandboxed agents whose shells both see
    $$ == 1 run formal at once in one shared checkout."""
    ns = ("unshare", "-r", "-p", "-f")
    procs = [subprocess.Popen([*ns, "bash", "formal/run_all.sh"], cwd=stub_root,
                              env=_env(stub_root, STUB_SLEEP="2"),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
             for _ in range(2)]
    outs = [p.communicate(timeout=60)[0] for p in procs]
    for p, out in zip(procs, outs):
        assert p.returncode == 0, out
        assert "Formal: 1 passed, 0 failed" in out
    assert len(list((stub_root.parent / "out").iterdir())) == 2
