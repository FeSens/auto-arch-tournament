"""Tests for orchestrator.write_run_summary — the canonical run_summary.json
emitted at end of each orchestrator invocation. This is the typed contract
the bench runner consumes; previously runner.py re-parsed log.jsonl with
its own classification logic, which drifted from orchestrator's emit shape
(rejected vs regression, etc.). Owning the schema on the orchestrator side
kills that drift."""
import json
from pathlib import Path

import pytest

from tools.orchestrator import write_run_summary


def _write_log(path: Path, entries: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")


def test_empty_log_produces_zero_summary(tmp_path):
    log = tmp_path / "cores" / "v1" / "experiments" / "log.jsonl"
    log.parent.mkdir(parents=True)
    log.write_text("")
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    assert s["iterations"] == 0
    assert s["accepted"] == 0
    assert s["rejected"] == 0
    assert s["broken"] == 0
    assert s["baseline_fitness"] is None
    assert s["final_fitness"] is None
    assert s["best_fitness"] is None
    assert s["best_round"] is None
    assert s["delta_pct"] is None
    assert s["broken_by_class"] == {}


def test_baseline_then_improvement(tmp_path):
    log = tmp_path / "log.jsonl"
    _write_log(log, [
        {"id": "baseline-x", "outcome": "improvement", "fitness": 300.0,
         "round_id": 0, "delta_pct": 0.0},
        {"id": "hyp-001-r1s0", "outcome": "improvement", "fitness": 327.33,
         "round_id": 1, "delta_pct": 9.11},
    ])
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    assert s["iterations"] == 2
    assert s["accepted"] == 2
    assert s["broken"] == 0
    assert s["baseline_fitness"] == 300.0
    assert s["final_fitness"] == 327.33
    assert s["best_fitness"] == 327.33
    assert s["best_round"] == 2
    assert s["delta_pct"] == pytest.approx((327.33 - 300.0) / 300.0 * 100)


def test_broken_by_class_groups_errors(tmp_path):
    log = tmp_path / "log.jsonl"
    _write_log(log, [
        {"outcome": "improvement", "fitness": 100.0, "round_id": 0},
        {"outcome": "broken", "error": "formal_failed: insn_beq_ch0"},
        {"outcome": "broken", "error": "formal_failed: pc_fwd_ch0"},
        {"outcome": "broken", "error": "implementation_compile_failed"},
        {"outcome": "broken", "error": "hypothesis_gen_failed: agent didn't write"},
    ])
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    assert s["broken"] == 4
    # The leading error class is the grouping key — bare error string after
    # the colon is dropped because the class is what aggregates across runs.
    assert s["broken_by_class"] == {
        "formal_failed": 2,
        "implementation_compile_failed": 1,
        "hypothesis_gen_failed": 1,
    }


def test_mixed_outcomes_baseline_derives(tmp_path):
    log = tmp_path / "log.jsonl"
    _write_log(log, [
        {"id": "baseline", "outcome": "improvement", "fitness": 282.82,
         "round_id": 0, "delta_pct": 0.0},
        {"id": "h1", "outcome": "improvement", "fitness": 327.33, "round_id": 1},
        {"id": "h2", "outcome": "regression", "fitness": 290.0, "round_id": 1},
        {"id": "h3", "outcome": "broken", "error": "formal_failed: x"},
    ])
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    assert s["iterations"] == 4
    assert s["accepted"] == 2
    assert s["rejected"] == 1
    assert s["broken"] == 1
    assert s["baseline_fitness"] == 282.82
    assert s["best_fitness"] == 327.33
    # Final fitness = last accepted's fitness.
    assert s["final_fitness"] == 327.33
    assert s["broken_by_class"] == {"formal_failed": 1}


def test_missing_log_writes_zero_summary(tmp_path):
    log = tmp_path / "nope.jsonl"  # does not exist
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    assert s["iterations"] == 0


def test_best_entry_fpga_fields_carried(tmp_path):
    """The best-fitness entry's lut4/ff/fmax_mhz/iterations/cycles/ipc_coremark
    must be carried in the summary so the per-rep row exposes microarch
    detail (LUT count, Fmax, IPC) without re-parsing log.jsonl downstream."""
    log = tmp_path / "log.jsonl"
    _write_log(log, [
        {"id": "baseline", "outcome": "improvement", "fitness": 282.82,
         "round_id": 0, "delta_pct": 0.0,
         "lut4": 9563, "ff": 1866, "fmax_mhz": 127.03,
         "iterations": 10, "cycles": 4491485, "ipc_coremark": 2e-06},
        {"id": "h1", "outcome": "improvement", "fitness": 525.04,
         "round_id": 10, "delta_pct": 85.6,
         "lut4": 5453, "ff": 2138, "fmax_mhz": 220.22,
         "iterations": 10, "cycles": 4194377, "ipc_coremark": 2e-06},
        {"id": "h2", "outcome": "regression", "fitness": 300.0,
         "round_id": 11, "lut4": 9000, "ff": 1900, "fmax_mhz": 150.0},
    ])
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    # Best entry is h1 — its FPGA fields propagate.
    assert s["best_fitness"] == 525.04
    assert s["best_lut4"] == 5453
    assert s["best_ff"] == 2138
    assert s["best_fmax_mhz"] == 220.22
    assert s["best_iterations"] == 10
    assert s["best_cycles"] == 4194377
    assert s["best_ipc_coremark"] == 2e-06


def test_best_entry_fields_absent_when_no_improvement(tmp_path):
    """No improvement rows ⇒ no best entry ⇒ best_* fields are None
    (so downstream consumers can treat 'no winner' uniformly)."""
    log = tmp_path / "log.jsonl"
    _write_log(log, [
        {"outcome": "broken", "error": "formal_failed: x"},
        {"outcome": "regression", "fitness": 250.0, "lut4": 9000},
    ])
    out = tmp_path / "summary.json"
    write_run_summary(log_path=log, out_path=out)
    s = json.loads(out.read_text())
    # best_fitness comes from any fitness row, not just improvements.
    # But best_* FPGA fields are anchored on the same entry, so when
    # no improvement exists they reflect the best (highest-fitness) row.
    assert s["best_lut4"] == 9000
