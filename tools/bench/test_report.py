"""Unit tests for the bench leaderboard renderer."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.bench.report import (
    aggregate,
    fmt_fitness,
    fmt_pct,
    load_results,
    paired_comparison,
    render_comparison_section,
    render_csv,
    render_markdown,
    wilcoxon_signed_rank,
)


def _write_results(p: Path, rows: list[dict]) -> None:
    p.write_text("\n".join(json.dumps(r) for r in rows) + "\n")


def test_load_results_empty(tmp_path: Path):
    assert load_results(tmp_path / "absent.jsonl") == []


def test_load_results_skips_garbage(tmp_path: Path):
    p = tmp_path / "results.jsonl"
    p.write_text(
        "not json\n"
        + json.dumps({"model": "a", "rep": 1, "status": "done",
                      "final_fitness": 300}) + "\n"
        + "\n"
    )
    rows = load_results(p)
    assert len(rows) == 1
    assert rows[0].model == "a"


def test_aggregate_mean_std_two_reps(tmp_path: Path):
    p = tmp_path / "r.jsonl"
    _write_results(p, [
        {"model": "a", "rep": 1, "status": "done", "final_fitness": 300.0,
         "best_fitness": 300.0, "best_round": 5, "iterations": 10,
         "accepted": 7, "wall_clock_sec": 3600},
        {"model": "a", "rep": 2, "status": "done", "final_fitness": 320.0,
         "best_fitness": 325.0, "best_round": 7, "iterations": 10,
         "accepted": 8, "wall_clock_sec": 3000},
    ])
    aggs = aggregate(load_results(p))
    assert len(aggs) == 1
    a = aggs[0]
    assert a.model == "a"
    assert a.n_reps_done == 2
    assert a.n_reps_failed == 0
    assert abs(a.fitness_mean - 310.0) < 1e-6
    assert a.fitness_std is not None and a.fitness_std > 0
    assert a.fitness_best == 325.0
    assert a.iters_to_best_mean == 6.0
    assert abs(a.pass_rate - 0.75) < 1e-6


def test_aggregate_failed_reps_counted_separately(tmp_path: Path):
    p = tmp_path / "r.jsonl"
    _write_results(p, [
        {"model": "a", "rep": 1, "status": "done", "final_fitness": 300.0},
        {"model": "a", "rep": 2, "status": "failed"},
        {"model": "a", "rep": 3, "status": "timed_out"},
    ])
    aggs = aggregate(load_results(p))
    assert aggs[0].n_reps_done == 1
    assert aggs[0].n_reps_failed == 2
    assert aggs[0].fitness_mean == 300.0
    assert aggs[0].fitness_std == 0.0  # single rep -> std treated as 0


def test_aggregate_orders_by_fitness_desc(tmp_path: Path):
    p = tmp_path / "r.jsonl"
    _write_results(p, [
        {"model": "low", "rep": 1, "status": "done", "final_fitness": 100.0},
        {"model": "high", "rep": 1, "status": "done", "final_fitness": 400.0},
        {"model": "mid", "rep": 1, "status": "done", "final_fitness": 200.0},
    ])
    aggs = aggregate(load_results(p))
    assert [a.model for a in aggs] == ["high", "mid", "low"]


def test_render_markdown_includes_all_models(tmp_path: Path):
    p = tmp_path / "r.jsonl"
    _write_results(p, [
        {"model": "opus-47", "rep": 1, "status": "done", "final_fitness": 320.0,
         "iterations": 10, "accepted": 8, "wall_clock_sec": 3600},
        {"model": "qwen3-coder", "rep": 1, "status": "done", "final_fitness": 240.0,
         "iterations": 10, "accepted": 5, "wall_clock_sec": 5400},
    ])
    aggs = aggregate(load_results(p))
    md = render_markdown(aggs)
    assert "opus-47" in md
    assert "qwen3-coder" in md
    assert "320.0" in md
    assert "240.0" in md


def test_render_csv_round_trip(tmp_path: Path):
    p = tmp_path / "r.jsonl"
    _write_results(p, [
        {"model": "a", "rep": 1, "status": "done", "final_fitness": 100.0},
    ])
    out = tmp_path / "lb.csv"
    render_csv(aggregate(load_results(p)), out)
    text = out.read_text()
    assert "model" in text
    assert "a" in text
    assert "100" in text


# Formatting helpers --------------------------------------------------


def test_fmt_fitness_handles_none():
    assert fmt_fitness(None, None) == "—"
    assert fmt_fitness(300.0, None) == "300.0"
    assert "± 5.0" in fmt_fitness(300.0, 5.0)


def test_fmt_pct_handles_none():
    assert fmt_pct(None) == "—"
    assert fmt_pct(0.5) == "50%"


# ---- paired Wilcoxon + comparison rendering ---------------------------


def test_wilcoxon_too_few_reps_returns_none_p():
    # n=4 — below the 5-pair threshold; p must be None.
    w, p = wilcoxon_signed_rank([1.0, 2.0, 3.0, 4.0])
    assert p is None


def test_wilcoxon_all_positive_diffs_one_sided_extreme():
    # 8 strictly-positive paired differences. W_minus = 0, W_plus = 36.
    # Two-sided p should be very small (~0.012 for n=8).
    w, p = wilcoxon_signed_rank([1, 2, 3, 4, 5, 6, 7, 8])
    assert w == 0.0
    assert p is not None and p < 0.05


def test_wilcoxon_excludes_zero_diffs():
    # A run where some diffs are zero. Wilcoxon convention drops them.
    # Effective n = 5 (positive diffs only).
    w, p = wilcoxon_signed_rank([0, 0, 0, 1, 2, 3, 4, 5])
    assert p is not None  # n_nonzero = 5, just above threshold


def test_paired_comparison_pairs_by_rep(tmp_path: Path):
    rows_path = tmp_path / "results.jsonl"
    _write_results(rows_path, [
        {"model": "treatment", "rep": 1, "status": "done",
         "best_fitness": 100.0, "iterations": 3, "accepted": 1,
         "rejected": 2, "broken": 0, "wall_clock_sec": 60,
         "total_cost_usd": 0.0, "total_tokens_in": 0, "total_tokens_out": 0},
        {"model": "treatment", "rep": 2, "status": "done",
         "best_fitness": 110.0, "iterations": 3, "accepted": 1,
         "rejected": 2, "broken": 0, "wall_clock_sec": 60,
         "total_cost_usd": 0.0, "total_tokens_in": 0, "total_tokens_out": 0},
        {"model": "static", "rep": 1, "status": "done",
         "best_fitness": 90.0, "iterations": 3, "accepted": 0,
         "rejected": 3, "broken": 0, "wall_clock_sec": 60,
         "total_cost_usd": 0.0, "total_tokens_in": 0, "total_tokens_out": 0},
        {"model": "static", "rep": 2, "status": "done",
         "best_fitness": 95.0, "iterations": 3, "accepted": 0,
         "rejected": 3, "broken": 0, "wall_clock_sec": 60,
         "total_cost_usd": 0.0, "total_tokens_in": 0, "total_tokens_out": 0},
    ])
    rows = load_results(rows_path)
    cmp = paired_comparison(rows, "treatment", "static")
    assert cmp["n_pairs"] == 2
    assert cmp["mean_diff"] == 12.5  # (100-90 + 110-95)/2
    assert cmp["treatment_wins"] == 2


def test_render_comparison_section_omits_when_no_static(tmp_path: Path):
    rows_path = tmp_path / "results.jsonl"
    _write_results(rows_path, [
        {"model": "a", "rep": 1, "status": "done", "best_fitness": 100.0,
         "iterations": 3, "accepted": 1, "rejected": 2, "broken": 0,
         "wall_clock_sec": 60, "total_cost_usd": 0.0,
         "total_tokens_in": 0, "total_tokens_out": 0},
    ])
    rows = load_results(rows_path)
    assert render_comparison_section(rows) == ""
