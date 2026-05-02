"""End-to-end smoke test for the bench harness.

Skipped by default — runs a real `make N=2 K=1 TARGET=bench` against a
real (cheap) model. Requires a working pi installation and a cheap-model
API key. Total cost ~$0.50.

Gate behind `BENCH_SMOKE=1` plus `--run-smoke` so accidental CI runs
don't burn dollars.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest


pytestmark = pytest.mark.skipif(
    os.environ.get("BENCH_SMOKE") != "1",
    reason="set BENCH_SMOKE=1 to enable real-API smoke test",
)


def _have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def test_pi_is_installed():
    assert _have("pi"), "install with `npm install -g @mariozechner/pi-coding-agent`"


def test_smoke_one_rep(tmp_path: Path):
    """Run a tiny benchmark: 1 model, 1 rep, N=2, K=1 — and confirm a
    leaderboard pops out.

    Requires:
      - OPENROUTER_API_KEY set (uses qwen3-coder, the cheapest model)
      - pi on PATH
      - A bench-fixture-v1 ref already built in this repo
    """
    if not os.environ.get("OPENROUTER_API_KEY"):
        pytest.skip("OPENROUTER_API_KEY not set")
    if not _have("pi"):
        pytest.skip("pi not installed")

    repo_root = Path(__file__).parent.parent.parent
    out = subprocess.run(
        ["git", "rev-parse", "--verify", "bench-fixture-v1"],
        cwd=repo_root, capture_output=True, text=True,
    )
    if out.returncode != 0:
        pytest.skip("bench-fixture-v1 not built; run `python -m tools.bench.build_fixture` first")

    results_dir = tmp_path / "bench"
    clone_base = tmp_path / "clones"
    cmd = [
        "python3", "-m", "tools.bench.runner",
        "--reps", "1", "--n", "2", "--k", "1",
        "--only", "qwen3-coder",
        "--clone-base", str(clone_base),
        "--results-dir", str(results_dir),
        "--results-jsonl", str(results_dir / "results.jsonl"),
        "--max-cost", "5",
        "--timeout-sec", "1800",
    ]
    out = subprocess.run(cmd, cwd=repo_root)
    assert out.returncode == 0

    # Verify outputs landed
    assert (results_dir / "results.jsonl").is_file()
    rep_dir = results_dir / "qwen3-coder" / "rep1"
    assert rep_dir.is_dir()
    assert (rep_dir / "summary.json").is_file()

    # Render leaderboard
    out = subprocess.run(
        ["python3", "-m", "tools.bench.report",
         "--results", str(results_dir / "results.jsonl"),
         "--out", str(results_dir)],
        cwd=repo_root,
    )
    assert out.returncode == 0
    assert (results_dir / "LEADERBOARD.md").is_file()
