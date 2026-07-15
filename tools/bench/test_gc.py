"""Tests for tools/bench/gc.py, the stale bench-run / formal-workdir sweeper.

Uses fabricated directory trees under tmp_path (no real sby/verilator/etc)
per the repo's tools/eval/test_formal_*.py convention. git commands are
real but local-only (git init + commit), fast enough for a unit test.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

from tools.bench import gc


def _git(args, cwd):
    subprocess.run(["git", *args], cwd=str(cwd), check=True,
                    capture_output=True)


def _make_git_repo(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    _git(["init", "-q"], path)
    _git(["-c", "user.email=t@t", "-c", "user.name=t", "commit",
          "--allow-empty", "-q", "-m", "init"], path)


# ---------- parse_slug ---------------------------------------------------


def test_parse_slug_simple():
    assert gc.parse_slug("opus-47-rep2") == ("opus-47", 2)


def test_parse_slug_multi_dash_model_name():
    assert gc.parse_slug("gpt-5_6-sol-rep1") == ("gpt-5_6-sol", 1)


def test_parse_slug_no_rep_suffix_returns_none():
    assert gc.parse_slug("just-a-directory") is None


def test_parse_slug_rep_zero():
    assert gc.parse_slug("m-rep0") == ("m", 0)


# ---------- find_stale_clones --------------------------------------------


def test_find_stale_clones_matches_existing_rep_dir(tmp_path):
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    (clone_base / "gpt-5_6-sol-rep1").mkdir(parents=True)
    (results_dir / "gpt-5_6-sol" / "rep1").mkdir(parents=True)

    stale = gc.find_stale_clones(clone_base, results_dir)

    assert stale == [clone_base / "gpt-5_6-sol-rep1"]


def test_find_stale_clones_ignores_clone_without_rep_dir(tmp_path):
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    (clone_base / "gpt-5_6-sol-rep1").mkdir(parents=True)
    # No matching bench/gpt-5_6-sol/rep1 -- this rep never finished /
    # published, so its clone is NOT stale-safe to remove.
    results_dir.mkdir(parents=True)

    stale = gc.find_stale_clones(clone_base, results_dir)

    assert stale == []


def test_find_stale_clones_ignores_unparseable_names(tmp_path):
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    (clone_base / "not-a-bench-slug").mkdir(parents=True)
    results_dir.mkdir(parents=True)

    stale = gc.find_stale_clones(clone_base, results_dir)

    assert stale == []


def test_find_stale_clones_missing_clone_base_returns_empty(tmp_path):
    assert gc.find_stale_clones(tmp_path / "nonexistent", tmp_path) == []


def test_find_stale_clones_multiple(tmp_path):
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    for slug, model, rep in [
        ("gpt-5_6-sol-rep1", "gpt-5_6-sol", 1),
        ("gpt-5_6-sol-rep2", "gpt-5_6-sol", 2),
        ("gpt-5_6-terra-rep3", "gpt-5_6-terra", 3),
    ]:
        (clone_base / slug).mkdir(parents=True)
        (results_dir / model / f"rep{rep}").mkdir(parents=True)

    stale = gc.find_stale_clones(clone_base, results_dir)

    assert sorted(p.name for p in stale) == [
        "gpt-5_6-sol-rep1", "gpt-5_6-sol-rep2", "gpt-5_6-terra-rep3",
    ]


# ---------- find_stale_formal_workdirs -----------------------------------


def test_find_stale_formal_workdirs_matches_pid_suffixed(tmp_path, monkeypatch):
    # Both PIDs are fixed literals with no relation to any process actually
    # running on the test host; force the liveness check deterministic
    # (dead) rather than depend on whatever happens to be at those PIDs.
    monkeypatch.setattr(gc.os, "kill",
                        lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError))
    cores = tmp_path / "cores"
    (cores / "bench-44577").mkdir(parents=True)
    (cores / "baseline-75670").mkdir(parents=True)

    stale = gc.find_stale_formal_workdirs(cores)

    assert sorted(p.name for p in stale) == ["baseline-75670", "bench-44577"]


def test_find_stale_formal_workdirs_skips_live_pid(tmp_path):
    # Real liveness check, no monkeypatch: this test process's own PID is
    # guaranteed alive for the duration of the test.
    cores = tmp_path / "cores"
    live_pid = os.getpid()
    (cores / f"bench-{live_pid}").mkdir(parents=True)

    stale = gc.find_stale_formal_workdirs(cores)

    assert stale == []


def test_find_stale_formal_workdirs_mixed_live_and_dead(tmp_path, monkeypatch):
    # A live SBY run's workdir (PID still alive) must never be matched for
    # deletion, even when a dead-PID workdir sits right next to it.
    cores = tmp_path / "cores"
    live_pid = os.getpid()
    dead_pid = 99_999_999
    (cores / f"bench-{live_pid}").mkdir(parents=True)
    (cores / f"baseline-{dead_pid}").mkdir(parents=True)

    real_kill = os.kill

    def fake_kill(pid, sig):
        if pid == dead_pid:
            raise ProcessLookupError
        return real_kill(pid, sig)

    monkeypatch.setattr(gc.os, "kill", fake_kill)

    stale = gc.find_stale_formal_workdirs(cores)

    assert [p.name for p in stale] == [f"baseline-{dead_pid}"]


def test_find_stale_formal_workdirs_ignores_tracked_upstream_cores(tmp_path):
    cores = tmp_path / "cores"
    for name in ("nerv", "picorv32", "serv", "VexRiscv"):
        (cores / name).mkdir(parents=True)

    stale = gc.find_stale_formal_workdirs(cores)

    assert stale == []


def test_find_stale_formal_workdirs_ignores_non_pid_names(tmp_path):
    cores = tmp_path / "cores"
    (cores / "bench").mkdir(parents=True)
    (cores / "v1-not-a-pid").mkdir(parents=True)

    stale = gc.find_stale_formal_workdirs(cores)

    assert stale == []


def test_find_stale_formal_workdirs_missing_dir_returns_empty(tmp_path):
    assert gc.find_stale_formal_workdirs(tmp_path / "nonexistent") == []


# ---------- archive_clone_forensics + verify_forensics -------------------


def test_archive_copies_orchestrator_log_and_env_json(tmp_path):
    clone = tmp_path / "clone"
    rep_dir = tmp_path / "rep1"
    _make_git_repo(clone)
    (clone / ".tmp").mkdir()
    (clone / ".tmp" / "orchestrator.log").write_text("log contents")
    (clone / ".tmp" / "env.json").write_text("{}")

    actions = gc.archive_clone_forensics(clone, rep_dir)

    assert (rep_dir / "orchestrator.log").read_text() == "log contents"
    assert (rep_dir / "env.json").read_text() == "{}"
    assert (rep_dir / "repo.bundle").is_file()
    assert any("orchestrator.log" in a for a in actions)
    assert any("env.json" in a for a in actions)
    assert any("repo.bundle" in a for a in actions)


def test_archive_does_not_overwrite_existing_files(tmp_path):
    clone = tmp_path / "clone"
    rep_dir = tmp_path / "rep1"
    _make_git_repo(clone)
    (clone / ".tmp").mkdir()
    (clone / ".tmp" / "orchestrator.log").write_text("new")
    rep_dir.mkdir(parents=True)
    (rep_dir / "orchestrator.log").write_text("original, keep me")
    (rep_dir / "repo.bundle").write_text("original bundle, keep me")

    gc.archive_clone_forensics(clone, rep_dir)

    assert (rep_dir / "orchestrator.log").read_text() == "original, keep me"
    assert (rep_dir / "repo.bundle").read_text() == "original bundle, keep me"


def test_archive_missing_source_files_skips_gracefully(tmp_path):
    clone = tmp_path / "clone"
    rep_dir = tmp_path / "rep1"
    _make_git_repo(clone)
    # No .tmp/ dir at all -- older clone predating the forensics feature.

    actions = gc.archive_clone_forensics(clone, rep_dir)

    assert not (rep_dir / "orchestrator.log").exists()
    assert not (rep_dir / "env.json").exists()
    # repo.bundle can still be created since the clone itself is a git repo.
    assert (rep_dir / "repo.bundle").is_file()


def test_verify_forensics_true_when_both_present(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    (rep_dir / "orchestrator.log").write_text("x")
    (rep_dir / "repo.bundle").write_text("x")

    assert gc.verify_forensics(rep_dir) is True


def test_verify_forensics_false_when_bundle_missing(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    (rep_dir / "orchestrator.log").write_text("x")

    assert gc.verify_forensics(rep_dir) is False


def test_verify_forensics_false_when_log_missing(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    (rep_dir / "repo.bundle").write_text("x")

    assert gc.verify_forensics(rep_dir) is False


# ---------- main(): dry-run vs --delete -----------------------------------


def _setup_fabricated_tree(tmp_path):
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    riscv_cores = tmp_path / "formal" / "riscv-formal" / "cores"

    clone = clone_base / "modelx-rep1"
    _make_git_repo(clone)
    (clone / ".tmp").mkdir()
    (clone / ".tmp" / "orchestrator.log").write_text("log")
    rep_dir = results_dir / "modelx" / "rep1"
    rep_dir.mkdir(parents=True)
    (rep_dir / "summary.json").write_text("{}")

    (riscv_cores / "bench-1234").mkdir(parents=True)
    (riscv_cores / "nerv").mkdir(parents=True)  # tracked, must survive

    return clone_base, results_dir, riscv_cores, clone, rep_dir


def test_main_dry_run_does_not_delete_anything(tmp_path, capsys, monkeypatch):
    # bench-1234's PID has no relation to any real process; force the
    # liveness check deterministic (dead) for this fixture.
    monkeypatch.setattr(gc.os, "kill",
                        lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError))
    clone_base, results_dir, riscv_cores, clone, rep_dir = \
        _setup_fabricated_tree(tmp_path)

    rc = gc.main([
        "--clone-base", str(clone_base),
        "--results-dir", str(results_dir),
        "--riscv-formal-cores", str(riscv_cores),
    ])

    assert rc == 0
    assert clone.is_dir()
    assert (riscv_cores / "bench-1234").is_dir()
    assert (riscv_cores / "nerv").is_dir()
    out = capsys.readouterr().out
    assert "modelx-rep1" in out
    assert "bench-1234" in out
    assert "nerv" not in out.split("bench-1234")[0].split("\n")[-1]


def test_main_delete_removes_clone_and_workdir(tmp_path, capsys, monkeypatch):
    # bench-1234's PID has no relation to any real process; force the
    # liveness check deterministic (dead) for this fixture.
    monkeypatch.setattr(gc.os, "kill",
                        lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError))
    clone_base, results_dir, riscv_cores, clone, rep_dir = \
        _setup_fabricated_tree(tmp_path)

    rc = gc.main([
        "--clone-base", str(clone_base),
        "--results-dir", str(results_dir),
        "--riscv-formal-cores", str(riscv_cores),
        "--delete",
    ])

    assert rc == 0
    assert not clone.exists()
    assert not (riscv_cores / "bench-1234").exists()
    assert (riscv_cores / "nerv").is_dir()  # tracked core untouched
    # Forensics archived before the clone was removed.
    assert (rep_dir / "orchestrator.log").read_text() == "log"
    assert (rep_dir / "repo.bundle").is_file()


def test_main_delete_skips_clone_with_no_forensics_source(tmp_path, capsys):
    # A clone with no .tmp/ and not even a git repo -- forensics can't be
    # reconstructed, so the sweeper must refuse to delete it rather than
    # silently destroying the only evidence of that rep.
    clone_base = tmp_path / "clones"
    results_dir = tmp_path / "bench"
    riscv_cores = tmp_path / "formal" / "riscv-formal" / "cores"
    clone = clone_base / "modelx-rep1"
    clone.mkdir(parents=True)  # not a git repo, no .tmp/
    rep_dir = results_dir / "modelx" / "rep1"
    rep_dir.mkdir(parents=True)

    rc = gc.main([
        "--clone-base", str(clone_base),
        "--results-dir", str(results_dir),
        "--riscv-formal-cores", str(riscv_cores),
        "--delete",
    ])

    assert clone.exists()
    out = capsys.readouterr().out
    assert "SKIP" in out.upper()
