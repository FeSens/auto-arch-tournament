"""Tests for tools/eval/holdout.py: the held-out-kernel eval module (E3
Task 3). Pure-function parser tests plus run_kernel/run_holdout tests with
subprocess calls monkeypatched -- no real simulator or build ever runs
here, matching the style of tools/eval/test_formal_workdir_cleanup.py and
tools/bench/test_runner.py's run_one_job forensics tests.
"""
import json
import math
import subprocess

import pytest

from tools.eval import holdout
from tools.eval.holdout import (
    HOLDOUT_KERNELS,
    _build_holdout_elfs,
    _build_sim_binary,
    _build_sim_env,
    _parse_sim_marker,
    _parse_uart_status,
    run_holdout,
    run_kernel,
)


def _marker(**overrides):
    base = {
        "ebreak": True,
        "maxcycles_hit": False,
        "oob": False,
        "bench_start_cycle": 1000,
        "bench_stop_cycle": 91000,
        "bench_bracketed": True,
        "uart": "HOLDOUT crc32 reps=90 status=PASS\n",
    }
    base.update(overrides)
    return base


# ---- _parse_sim_marker --------------------------------------------------


def test_parse_sim_marker_takes_last_line():
    stdout = (
        '{"valid":1,"order":0}\n'
        '{"valid":1,"order":1}\n'
        + json.dumps(_marker()) + "\n"
    )
    marker = _parse_sim_marker(stdout)
    assert marker["ebreak"] is True
    assert marker["bench_stop_cycle"] == 91000


def test_parse_sim_marker_empty_raises():
    with pytest.raises(ValueError, match="no output"):
        _parse_sim_marker("")


def test_parse_sim_marker_malformed_raises():
    with pytest.raises(ValueError, match="malformed sim output"):
        _parse_sim_marker("not json at all\n")


# ---- _parse_uart_status --------------------------------------------------


def test_parse_uart_status_pass():
    reps, passed = _parse_uart_status("HOLDOUT crc32 reps=90 status=PASS\n", "crc32")
    assert reps == 90
    assert passed is True


def test_parse_uart_status_fail():
    reps, passed = _parse_uart_status("HOLDOUT crc32 reps=90 status=FAIL\n", "crc32")
    assert reps == 90
    assert passed is False


def test_parse_uart_status_missing_line():
    reps, passed = _parse_uart_status("garbage output, no marker\n", "crc32")
    assert reps == 0
    assert passed is False


def test_parse_uart_status_wrong_kernel_name():
    # Defends against a mixed-up ELF/kernel pairing silently validating.
    reps, passed = _parse_uart_status("HOLDOUT dhrystone reps=6000 status=PASS\n", "crc32")
    assert reps == 0
    assert passed is False


# ---- run_kernel -----------------------------------------------------------


def _touch_elf(worktree, kernel):
    elf = worktree / "bench" / "holdout" / "build" / f"{kernel}.elf"
    elf.parent.mkdir(parents=True, exist_ok=True)
    elf.write_bytes(b"")
    return elf


def _fake_run_pgroup(stdout):
    def fn(args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout, "")
    return fn


def test_run_kernel_pass(tmp_path, monkeypatch):
    _touch_elf(tmp_path, "crc32")
    monkeypatch.setattr(holdout, "run_pgroup", _fake_run_pgroup(json.dumps(_marker()) + "\n"))

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is True
    assert result["cycles"] == 90000
    assert result["reps"] == 90


def test_run_kernel_uart_status_fail(tmp_path, monkeypatch):
    _touch_elf(tmp_path, "crc32")
    marker = _marker(uart="HOLDOUT crc32 reps=90 status=FAIL\n")
    monkeypatch.setattr(holdout, "run_pgroup", _fake_run_pgroup(json.dumps(marker) + "\n"))

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is False
    assert "uart_status" in result["reason"]


def test_run_kernel_missing_bracket(tmp_path, monkeypatch):
    _touch_elf(tmp_path, "crc32")
    marker = _marker(bench_bracketed=False)
    monkeypatch.setattr(holdout, "run_pgroup", _fake_run_pgroup(json.dumps(marker) + "\n"))

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is False
    assert "bench_markers_missing" in result["reason"]


def test_run_kernel_oob(tmp_path, monkeypatch):
    _touch_elf(tmp_path, "crc32")
    marker = _marker(oob=True)
    monkeypatch.setattr(holdout, "run_pgroup", _fake_run_pgroup(json.dumps(marker) + "\n"))

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is False
    assert "oob" in result["reason"]


def test_run_kernel_no_ebreak_maxcycles(tmp_path, monkeypatch):
    _touch_elf(tmp_path, "crc32")
    marker = _marker(ebreak=False, maxcycles_hit=True)
    monkeypatch.setattr(holdout, "run_pgroup", _fake_run_pgroup(json.dumps(marker) + "\n"))

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is False
    assert "maxcycles" in result["reason"]


def test_run_kernel_missing_elf_skips_sim(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(holdout, "run_pgroup", lambda *a, **k: calls.append(a) or None)

    result = run_kernel(tmp_path, tmp_path / "cosim_sim", "crc32")

    assert result["validated"] is False
    assert "missing_elf" in result["reason"]
    assert calls == []


# ---- run_holdout ----------------------------------------------------------


def _setup_worktree(tmp_path, target="v1"):
    for kernel in HOLDOUT_KERNELS:
        _touch_elf(tmp_path, kernel)
    obj_dir = tmp_path / "cores" / target / "obj_dir"
    obj_dir.mkdir(parents=True)
    (obj_dir / "cosim_sim").write_bytes(b"")
    return tmp_path


def test_run_holdout_all_pass_computes_geomean(tmp_path, monkeypatch):
    _setup_worktree(tmp_path)
    # Distinct cycles/reps per kernel so the geomean isn't accidentally
    # equal to any single kernel's iter_s.
    per_kernel = {
        "dhrystone":    (3_000_000, 6000),
        "aha-mont64":   (2_000_000, 200),
        "crc32":        (1_000_000, 90),
        "matmult-int":  (4_000_000, 15),
        "edn":          (5_000_000, 50),
    }

    def fake_run_pgroup(args, **kwargs):
        elf_path = str(args[1])
        kernel = next(k for k in HOLDOUT_KERNELS if f"{k}.elf" in elf_path)
        cycles, reps = per_kernel[kernel]
        marker = _marker(
            bench_start_cycle=0, bench_stop_cycle=cycles,
            uart=f"HOLDOUT {kernel} reps={reps} status=PASS\n",
        )
        return subprocess.CompletedProcess(args, 0, json.dumps(marker) + "\n", "")

    monkeypatch.setattr(holdout, "run_pgroup", fake_run_pgroup)
    # Nothing should be built -- ELFs and sim binary already exist.
    monkeypatch.setattr(subprocess, "run",
                         lambda *a, **k: pytest.fail("no build should happen"))

    fmax_mhz = 100.0
    result = run_holdout(str(tmp_path), "v1", fmax_mhz)

    assert result["all_validated"] is True
    expected_iters = []
    for kernel, (cycles, reps) in per_kernel.items():
        expected = fmax_mhz * 1e6 * reps / cycles
        assert result["kernels"][kernel]["iter_s"] == pytest.approx(expected)
        assert result["kernels"][kernel]["validated"] is True
        expected_iters.append(expected)

    expected_geomean = math.exp(sum(math.log(v) for v in expected_iters) / len(expected_iters))
    assert result["geomean_iter_s"] == pytest.approx(expected_geomean)


def test_run_holdout_partial_fail_excludes_from_geomean(tmp_path, monkeypatch):
    _setup_worktree(tmp_path)

    def fake_run_pgroup(args, **kwargs):
        elf_path = str(args[1])
        kernel = next(k for k in HOLDOUT_KERNELS if f"{k}.elf" in elf_path)
        if kernel == "edn":
            marker = _marker(oob=True)
        else:
            marker = _marker(
                bench_start_cycle=0, bench_stop_cycle=1_000_000,
                uart=f"HOLDOUT {kernel} reps=100 status=PASS\n",
            )
        return subprocess.CompletedProcess(args, 0, json.dumps(marker) + "\n", "")

    monkeypatch.setattr(holdout, "run_pgroup", fake_run_pgroup)

    result = run_holdout(str(tmp_path), "v1", 100.0)

    assert result["all_validated"] is False
    assert result["kernels"]["edn"]["validated"] is False
    assert result["kernels"]["edn"]["iter_s"] == 0.0
    validated = [k for k, v in result["kernels"].items() if v["validated"]]
    assert len(validated) == 4
    # geomean must be computed over the 4 validated kernels only, all of
    # which share the same iter_s here -- so geomean == that shared value.
    expected = 100.0 * 1e6 * 100 / 1_000_000
    assert result["geomean_iter_s"] == pytest.approx(expected)


def test_run_holdout_zero_validated_geomean_is_zero(tmp_path, monkeypatch):
    _setup_worktree(tmp_path)

    def fake_run_pgroup(args, **kwargs):
        marker = _marker(oob=True)
        return subprocess.CompletedProcess(args, 0, json.dumps(marker) + "\n", "")

    monkeypatch.setattr(holdout, "run_pgroup", fake_run_pgroup)

    result = run_holdout(str(tmp_path), "v1", 100.0)

    assert result["all_validated"] is False
    assert result["geomean_iter_s"] == 0.0
    assert all(not v["validated"] for v in result["kernels"].values())


# ---- build steps (subprocess-driven, all monkeypatched) -------------------


def test_build_holdout_elfs_skips_when_all_present(tmp_path, monkeypatch):
    for kernel in HOLDOUT_KERNELS:
        _touch_elf(tmp_path, kernel)
    monkeypatch.setattr(subprocess, "run",
                         lambda *a, **k: pytest.fail("make should not run"))

    _build_holdout_elfs(tmp_path)  # must not raise, must not call subprocess.run


def test_build_holdout_elfs_invokes_make_when_missing(tmp_path, monkeypatch):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append((cmd, kwargs.get("cwd")))
        for kernel in HOLDOUT_KERNELS:
            _touch_elf(tmp_path, kernel)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)

    _build_holdout_elfs(tmp_path)

    assert len(calls) == 1
    cmd, cwd = calls[0]
    assert cmd == ["make", "-f", "bench/holdout/Makefile", "all"]
    assert cwd == tmp_path


def test_build_holdout_elfs_raises_fatal_on_make_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **k: subprocess.CompletedProcess(a[0], 1, "", "gcc: error"),
    )

    with pytest.raises(RuntimeError, match="FATAL"):
        _build_holdout_elfs(tmp_path)


def test_build_sim_env_reads_nret_default(tmp_path):
    (tmp_path / "cores" / "v1").mkdir(parents=True)
    env = _build_sim_env(tmp_path, "v1")
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["OBJ_DIR"] == "cores/v1/obj_dir"
    assert env["NRET"] == "2"


def test_build_sim_env_reads_nret_from_core_yaml(tmp_path):
    core_dir = tmp_path / "cores" / "v1"
    core_dir.mkdir(parents=True)
    (core_dir / "core.yaml").write_text("nret: 1\n")
    env = _build_sim_env(tmp_path, "v1")
    assert env["NRET"] == "1"


def test_build_sim_binary_skips_when_present(tmp_path, monkeypatch):
    obj_dir = tmp_path / "cores" / "v1" / "obj_dir"
    obj_dir.mkdir(parents=True)
    (obj_dir / "cosim_sim").write_bytes(b"")
    monkeypatch.setattr(subprocess, "run",
                         lambda *a, **k: pytest.fail("build.sh should not run"))

    sim_bin = _build_sim_binary(tmp_path, "v1")

    assert sim_bin == obj_dir / "cosim_sim"


def test_build_sim_binary_raises_fatal_on_build_failure(tmp_path, monkeypatch):
    (tmp_path / "cores" / "v1").mkdir(parents=True)
    monkeypatch.setattr(
        subprocess, "run",
        lambda *a, **k: subprocess.CompletedProcess(a[0], 1, "", "verilator: error"),
    )

    with pytest.raises(RuntimeError, match="FATAL"):
        _build_sim_binary(tmp_path, "v1")


# ---- run_holdout holdout_dir (E3 Task 5 interface extension) --------------
#
# Champion clones from repo.bundle lack bench/holdout by design (the E3
# guard bakes its removal into rep clone history -- see tools/eval's E3
# Task 2), but the held-out kernels are core-independent, so their ELFs
# can be built/looked up from a separate source-of-truth directory
# (holdout_dir) while the simulator, which depends on the champion's RTL,
# keeps building/running out of worktree.


def test_run_holdout_holdout_dir_drives_elf_worktree_drives_sim(tmp_path, monkeypatch):
    worktree = tmp_path / "worktree"
    holdout_dir = tmp_path / "holdout"
    worktree.mkdir()
    holdout_dir.mkdir()

    obj_dir = worktree / "cores" / "v1" / "obj_dir"
    obj_dir.mkdir(parents=True)
    (obj_dir / "cosim_sim").write_bytes(b"")

    for kernel in HOLDOUT_KERNELS:
        _touch_elf(holdout_dir, kernel)

    seen_cwds = []

    def fake_run_pgroup(args, **kwargs):
        elf_path = str(args[1])
        assert str(holdout_dir) in elf_path, elf_path
        assert str(worktree) not in elf_path, elf_path
        seen_cwds.append(kwargs.get("cwd"))
        kernel = next(k for k in HOLDOUT_KERNELS if f"{k}.elf" in elf_path)
        marker = _marker(
            bench_start_cycle=0, bench_stop_cycle=1_000_000,
            uart=f"HOLDOUT {kernel} reps=100 status=PASS\n",
        )
        return subprocess.CompletedProcess(args, 0, json.dumps(marker) + "\n", "")

    monkeypatch.setattr(holdout, "run_pgroup", fake_run_pgroup)
    # ELFs already exist in holdout_dir and cosim_sim already exists in
    # worktree, so no build should be triggered on either path.
    monkeypatch.setattr(subprocess, "run",
                         lambda *a, **k: pytest.fail("no build should happen"))

    result = run_holdout(str(worktree), "v1", 100.0, holdout_dir=str(holdout_dir))

    assert result["all_validated"] is True
    # Simulator invocation cwd tracks worktree (sim/RTL side), not
    # holdout_dir (kernel side), regardless of where the ELFs came from.
    assert seen_cwds and all(cwd == worktree.resolve() for cwd in seen_cwds)


def test_run_holdout_default_holdout_dir_is_worktree(tmp_path, monkeypatch):
    # No holdout_dir given: unchanged behavior, ELFs looked up under
    # worktree exactly as before this kwarg existed.
    _setup_worktree(tmp_path)

    def fake_run_pgroup(args, **kwargs):
        elf_path = str(args[1])
        assert str(tmp_path) in elf_path
        kernel = next(k for k in HOLDOUT_KERNELS if f"{k}.elf" in elf_path)
        marker = _marker(
            bench_start_cycle=0, bench_stop_cycle=1_000_000,
            uart=f"HOLDOUT {kernel} reps=100 status=PASS\n",
        )
        return subprocess.CompletedProcess(args, 0, json.dumps(marker) + "\n", "")

    monkeypatch.setattr(holdout, "run_pgroup", fake_run_pgroup)

    result = run_holdout(str(tmp_path), "v1", 100.0)

    assert result["all_validated"] is True
