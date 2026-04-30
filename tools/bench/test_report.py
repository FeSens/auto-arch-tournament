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
    render_csv,
    render_markdown,
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
