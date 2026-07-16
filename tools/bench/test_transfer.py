"""Tests for tools/bench/transfer.py: the E3 Task 5 transfer scorer.

Fabricates a mini rep dir (a tiny git repo bundled with `git bundle
create`, containing a cores/bench/rtl marker file, plus a fake
log.jsonl / summary.json) and drives score_rep()/main() against it.
run_holdout is monkeypatched throughout -- it needs a real build+sim,
which is covered separately by the real smoke run documented in the
report, not by this unit suite. The git bundle-clone path itself is
real (no mocking of git): cheap, fast, deterministic, and it is the
part of this module most likely to have an interface bug.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from tools.bench import transfer
from tools.bench.transfer import (
    MissingBundleError,
    _build_kernels_once,
    _champion_fmax_mhz,
    _clone_champion,
    _coremark_iter_s,
    _parse_rep_dir,
    main,
    score_rep,
)


# ---- fixtures ---------------------------------------------------------


def _git(args, cwd):
    subprocess.run(["git"] + args, cwd=cwd, check=True, capture_output=True)


def _make_bundle(tmp_path: Path) -> Path:
    """A tiny real git repo, bundled, containing a cores/bench/rtl
    marker file -- stands in for a champion clone's final tree."""
    src = tmp_path / "src_repo"
    src.mkdir()
    _git(["init", "-q"], cwd=src)
    _git(["config", "user.email", "t@example.com"], cwd=src)
    _git(["config", "user.name", "Test"], cwd=src)
    rtl_dir = src / "cores" / "bench" / "rtl"
    rtl_dir.mkdir(parents=True)
    (rtl_dir / "core.sv").write_text("// marker\n")
    _git(["add", "."], cwd=src)
    _git(["commit", "-q", "-m", "init", "--no-gpg-sign"], cwd=src)

    bundle = tmp_path / "repo.bundle"
    _git(["bundle", "create", str(bundle), "--all"], cwd=src)
    return bundle


def _write_log(rep_dir: Path, rows: list[dict]) -> None:
    with (rep_dir / "log.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")


def _write_summary(rep_dir: Path, **fields) -> None:
    base = {"model": "m", "rep": 1, "best_fmax_mhz": 111.0, "final_fitness": 999.0}
    base.update(fields)
    (rep_dir / "summary.json").write_text(json.dumps(base))


def _make_rep_dir(tmp_path: Path, model="gpt-5_6-sol", rep=1, with_bundle=True) -> Path:
    rep_dir = tmp_path / "bench" / model / f"rep{rep}"
    rep_dir.mkdir(parents=True)
    if with_bundle:
        bundle = _make_bundle(tmp_path)
        (rep_dir / "repo.bundle").write_bytes(bundle.read_bytes())
    return rep_dir


_FAKE_HOLDOUT_RESULT = {
    "kernels": {"dhrystone": {"cycles": 1, "reps": 1, "iter_s": 1.0, "validated": True}},
    "geomean_iter_s": 42.0,
    "all_validated": True,
}


# ---- _parse_rep_dir -----------------------------------------------------


def test_parse_rep_dir_extracts_model_and_rep():
    model, rep = _parse_rep_dir(Path("bench/gpt-5_6-sol/rep1"))
    assert model == "gpt-5_6-sol"
    assert rep == 1


def test_parse_rep_dir_multi_digit_rep():
    model, rep = _parse_rep_dir(Path("/abs/path/bench/kimi-k2_6/rep12"))
    assert model == "kimi-k2_6"
    assert rep == 12


def test_parse_rep_dir_rejects_bad_name():
    with pytest.raises(ValueError, match="rep"):
        _parse_rep_dir(Path("bench/gpt-5_6-sol/notarep"))


# ---- _champion_fmax_mhz ---------------------------------------------------


def test_champion_fmax_picks_last_improvement_not_best(tmp_path, capsys):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    _write_log(rep_dir, [
        # baseline retest may be the first improvement row
        {"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 127.0, "fitness": 282.82},
        {"round_id": 1, "slot": 0, "outcome": "regression", "fmax_mhz": 999.0, "fitness": 10.0},
        # highest fmax of all rows, but NOT the last improvement -- must be ignored
        {"round_id": 2, "slot": 0, "outcome": "improvement", "fmax_mhz": 150.0, "fitness": 300.0},
        {"round_id": 3, "slot": 0, "outcome": "broken", "fmax_mhz": None},
        # last improvement row: this is the champion, even though its fmax
        # is lower than round 2's
        {"round_id": 4, "slot": 0, "outcome": "improvement", "fmax_mhz": 140.0, "fitness": 470.8},
    ])
    _write_summary(rep_dir, best_fmax_mhz=150.0)

    fmax = _champion_fmax_mhz(rep_dir)

    assert fmax == 140.0
    assert capsys.readouterr().err == ""  # no fallback warning needed


def test_champion_fmax_falls_back_to_summary_with_warning(tmp_path, capsys):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    _write_log(rep_dir, [
        {"round_id": 0, "slot": 0, "outcome": "regression", "fmax_mhz": 100.0},
        {"round_id": 1, "slot": 0, "outcome": "broken", "fmax_mhz": None},
    ])
    _write_summary(rep_dir, best_fmax_mhz=123.45)

    fmax = _champion_fmax_mhz(rep_dir)

    assert fmax == 123.45
    err = capsys.readouterr().err
    assert "WARNING" in err
    assert "123.45" in err


# ---- _coremark_iter_s -----------------------------------------------------


def test_coremark_iter_s_reads_final_fitness(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    _write_summary(rep_dir, final_fitness=470.8)

    assert _coremark_iter_s(rep_dir) == 470.8


# ---- _clone_champion / missing bundle -------------------------------------


def test_clone_champion_missing_bundle_raises(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()  # no repo.bundle

    with pytest.raises(MissingBundleError, match="repo.bundle"):
        _clone_champion(rep_dir, tmp_path / "dest")


def test_clone_champion_checks_out_marker_file(tmp_path):
    rep_dir = tmp_path / "rep1"
    rep_dir.mkdir()
    bundle = _make_bundle(tmp_path)
    (rep_dir / "repo.bundle").write_bytes(bundle.read_bytes())

    dest = tmp_path / "clonedest"
    _clone_champion(rep_dir, dest)

    assert (dest / "cores" / "bench" / "rtl" / "core.sv").exists()


# ---- score_rep --------------------------------------------------------


def test_score_rep_missing_bundle_raises(tmp_path, monkeypatch):
    rep_dir = _make_rep_dir(tmp_path, with_bundle=False)
    _write_log(rep_dir, [{"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 100.0}])
    _write_summary(rep_dir)
    monkeypatch.setattr(transfer, "run_holdout", lambda *a, **k: pytest.fail("must not run"))

    with pytest.raises(MissingBundleError):
        score_rep(rep_dir, tmp_path / "repo_root")


def test_score_rep_produces_complete_row(tmp_path, monkeypatch):
    rep_dir = _make_rep_dir(tmp_path, model="gpt-5_6-sol", rep=1)
    _write_log(rep_dir, [
        {"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 127.0},
        {"round_id": 1, "slot": 0, "outcome": "improvement", "fmax_mhz": 199.92},
    ])
    _write_summary(rep_dir, best_fmax_mhz=199.92, final_fitness=470.8)

    seen = {}

    def fake_run_holdout(clone_dir, target, fmax_mhz, holdout_dir=None):
        seen["clone_dir"] = clone_dir
        seen["target"] = target
        seen["fmax_mhz"] = fmax_mhz
        seen["holdout_dir"] = holdout_dir
        # champion RTL marker must be present in the clone by the time
        # run_holdout is called
        assert (Path(clone_dir) / "cores" / "bench" / "rtl" / "core.sv").exists()
        return _FAKE_HOLDOUT_RESULT

    monkeypatch.setattr(transfer, "run_holdout", fake_run_holdout)
    repo_root = tmp_path / "repo_root"

    row = score_rep(rep_dir, repo_root)

    assert seen["target"] == "bench"
    assert seen["fmax_mhz"] == 199.92
    assert seen["holdout_dir"] == str(repo_root)
    assert row == {
        "model": "gpt-5_6-sol",
        "rep": 1,
        "champion_fmax_mhz": 199.92,
        "kernels": _FAKE_HOLDOUT_RESULT["kernels"],
        "geomean_iter_s": 42.0,
        "coremark_iter_s": 470.8,
        "timestamp": row["timestamp"],
    }
    assert row["timestamp"]  # non-empty, ISO-ish; exact format not pinned here

    # scratch clone must be cleaned up (finally block), and the rep dir
    # itself must never be mutated
    assert not Path(seen["clone_dir"]).exists()
    assert not (rep_dir / "cores").exists()


def test_score_rep_cleans_up_scratch_even_on_holdout_failure(tmp_path, monkeypatch):
    rep_dir = _make_rep_dir(tmp_path)
    _write_log(rep_dir, [{"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 100.0}])
    _write_summary(rep_dir)

    captured = {}

    def fake_run_holdout(clone_dir, target, fmax_mhz, holdout_dir=None):
        captured["clone_dir"] = clone_dir
        raise RuntimeError("boom")

    monkeypatch.setattr(transfer, "run_holdout", fake_run_holdout)

    with pytest.raises(RuntimeError, match="boom"):
        score_rep(rep_dir, tmp_path / "repo_root")

    assert not Path(captured["clone_dir"]).exists()


# ---- main (CLI) --------------------------------------------------------


def test_main_missing_bundle_exits_3(tmp_path, monkeypatch, capsys):
    rep_dir = _make_rep_dir(tmp_path, with_bundle=False)
    _write_log(rep_dir, [{"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 100.0}])
    _write_summary(rep_dir)
    monkeypatch.setattr(transfer, "_build_kernels_once", lambda repo_root: None)
    monkeypatch.setattr(transfer, "run_holdout", lambda *a, **k: pytest.fail("must not run"))

    out_path = tmp_path / "out" / "results.jsonl"
    rc = main([str(rep_dir), "--out", str(out_path)])

    assert rc == 3
    assert "repo.bundle" in capsys.readouterr().err
    assert not out_path.exists()


def test_main_appends_row_to_out_file(tmp_path, monkeypatch):
    rep_dir = _make_rep_dir(tmp_path)
    _write_log(rep_dir, [{"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 199.92}])
    _write_summary(rep_dir, final_fitness=470.8)

    monkeypatch.setattr(transfer, "_build_kernels_once", lambda repo_root: None)
    monkeypatch.setattr(transfer, "run_holdout", lambda *a, **k: _FAKE_HOLDOUT_RESULT)

    out_path = tmp_path / "out" / "results.jsonl"
    # pre-seed one existing row to prove append (not overwrite)
    out_path.parent.mkdir(parents=True)
    out_path.write_text(json.dumps({"pre": "existing"}) + "\n")

    rc = main([str(rep_dir), "--out", str(out_path)])

    assert rc == 0
    lines = out_path.read_text().splitlines()
    assert len(lines) == 2
    assert json.loads(lines[0]) == {"pre": "existing"}
    row = json.loads(lines[1])
    assert row["model"] == "gpt-5_6-sol"
    assert row["rep"] == 1
    assert row["champion_fmax_mhz"] == 199.92
    assert row["coremark_iter_s"] == 470.8


def test_main_builds_kernels_before_cloning(tmp_path, monkeypatch):
    rep_dir = _make_rep_dir(tmp_path)
    _write_log(rep_dir, [{"round_id": 0, "slot": 0, "outcome": "improvement", "fmax_mhz": 100.0}])
    _write_summary(rep_dir)

    order = []
    monkeypatch.setattr(transfer, "_build_kernels_once",
                         lambda repo_root: order.append("build_kernels"))

    real_clone = transfer._clone_champion

    def spy_clone(rd, dest):
        order.append("clone_champion")
        return real_clone(rd, dest)

    monkeypatch.setattr(transfer, "_clone_champion", spy_clone)
    monkeypatch.setattr(transfer, "run_holdout", lambda *a, **k: _FAKE_HOLDOUT_RESULT)

    rc = main([str(rep_dir), "--out", str(tmp_path / "out.jsonl")])

    assert rc == 0
    assert order == ["build_kernels", "clone_champion"]


def test_build_kernels_once_delegates_to_holdout_module(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(transfer.holdout, "_build_holdout_elfs", lambda root: calls.append(root))

    _build_kernels_once(tmp_path)

    assert calls == [tmp_path]
