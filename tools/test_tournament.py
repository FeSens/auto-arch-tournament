import pytest
"""Unit tests for tools/tournament.py pure helpers (no claude / no FPGA)."""
from tools.tournament import (
    allocate_round_ids,
    category_for_slot,
    pick_winner,
)



@pytest.fixture(autouse=True)
def _v1_strict_margin(monkeypatch):
    """Winner-selection tests use small score gaps; the V2 acceptance margin
    has its own tests in test_accept_rule.py."""
    from tools import accept_rule
    monkeypatch.setattr(accept_rule, "ACCEPT_MARGIN_LN", 0.0)

def test_allocate_round_ids_basic():
    ids = allocate_round_ids(round_id=1, tournament_size=3,
                             today="20260427", first_seq=2)
    assert ids == [
        "hyp-20260427-002-r1s0",
        "hyp-20260427-003-r1s1",
        "hyp-20260427-004-r1s2",
    ]


def test_allocate_round_ids_n_equals_one():
    ids = allocate_round_ids(round_id=1, tournament_size=1,
                             today="20260427", first_seq=1)
    assert ids == ["hyp-20260427-001-r1s0"]


def test_category_for_slot_cycles_through_enum():
    assert category_for_slot(0) == "micro_opt"
    assert category_for_slot(1) == "structural"
    assert category_for_slot(2) == "predictor"
    assert category_for_slot(3) == "memory"
    assert category_for_slot(4) == "extension"
    # Slot 5 wraps:
    assert category_for_slot(5) == "micro_opt"


def _entry(slot, fitness, outcome="improvement"):
    return {"slot": slot, "fitness": fitness, "outcome": outcome}


def test_pick_winner_highest_fitness_above_baseline():
    entries = [_entry(0, 280.0), _entry(1, 290.0), _entry(2, 285.0)]
    winner = pick_winner(entries, current_best=282.82)
    assert winner["slot"] == 1


def test_pick_winner_no_slot_beats_baseline_returns_none():
    entries = [_entry(0, 280.0), _entry(1, 281.0), _entry(2, 282.0)]
    winner = pick_winner(entries, current_best=282.82)
    assert winner is None


def test_pick_winner_skips_broken_slots():
    entries = [
        {"slot": 0, "fitness": None, "outcome": "broken"},
        {"slot": 1, "fitness": 290.0, "outcome": "improvement"},
        {"slot": 2, "fitness": None, "outcome": "placement_failed"},
    ]
    winner = pick_winner(entries, current_best=282.82)
    assert winner["slot"] == 1


def test_pick_winner_all_broken_returns_none():
    entries = [
        {"slot": 0, "fitness": None, "outcome": "broken"},
        {"slot": 1, "fitness": None, "outcome": "broken"},
    ]
    winner = pick_winner(entries, current_best=282.82)
    assert winner is None


def test_pick_winner_strict_greater_than():
    """fitness == current_best is NOT a winner — strict > only.

    The N=1 regression fixture relies on this: a baseline-retest scoring
    exactly 282.82 against a current_best of 282.82 must log as 'regression',
    not 'improvement'. If pick_winner ever changes to >=, the fixture's
    expected outcome would silently flip.
    """
    entries = [_entry(0, 282.82)]
    assert pick_winner(entries, current_best=282.82) is None


def test_pick_winner_tie_breaks_to_lowest_slot():
    """Two slots with identical fitness — the lower slot index wins."""
    entries = [_entry(0, 290.0), _entry(1, 290.0), _entry(2, 290.0)]
    winner = pick_winner(entries, current_best=282.82)
    assert winner["slot"] == 0


def test_phase_gate_serializes_under_capacity_one(tmp_path, monkeypatch):
    """Two threads contending on the formal gate must not overlap."""
    import threading, time
    # Keep the machine-wide formal lock out of the real /tmp.
    monkeypatch.setenv("AAT_MACHINE_LOCK_DIR", str(tmp_path))
    from tools.tournament import phase_gate

    overlap = {'count': 0, 'max': 0}
    in_section = {'n': 0}
    lock = threading.Lock()

    def worker():
        with phase_gate('formal'):
            with lock:
                in_section['n'] += 1
                overlap['max'] = max(overlap['max'], in_section['n'])
            time.sleep(0.05)
            with lock:
                in_section['n'] -= 1

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert overlap['max'] == 1, "phase_gate('formal') failed to serialize"


# ── target-aware pick_winner ───────────────────────────────────────────────
def _entry(slot, fitness=None, lut4=None, outcome="regression"):
    return {"slot": slot, "fitness": fitness, "lut4": lut4, "outcome": outcome}


def test_pick_winner_no_targets_legacy_behavior():
    from tools.tournament import pick_winner
    entries = [_entry(0, 290), _entry(1, 320), _entry(2, 310)]
    w = pick_winner(entries, current_best=300)
    assert w["slot"] == 1


def test_pick_winner_dual_target_phase1():
    # Targets (300, 3000). Champion (200, 5000). Slot 0 closes both
    # deficits a bit; slot 1 adds LUT but no perf benefit.
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=290, lut4=4500),
        _entry(1, fitness=205, lut4=5500),
    ]
    w = pick_winner(entries, current_best=200, current_lut=5000,
                    coremark_target=300, lut_target=3000)
    assert w is not None and w["slot"] == 0


def test_pick_winner_dual_target_rejects_no_progress():
    # Phase 2 (both targets met). Slot 0 trades perf for LUT — strict Pareto
    # rejects. Slot 1 makes things worse on both axes.
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=340, lut4=2950),
        _entry(1, fitness=300, lut4=3000),
    ]
    w = pick_winner(entries, current_best=320, current_lut=2900,
                    coremark_target=300, lut_target=3000)
    assert w is None


def test_pick_winner_dual_target_phase2_strict_dominance():
    # Phase 2, slot 0 strictly dominates (perf up, lut down).
    from tools.tournament import pick_winner
    entries = [
        _entry(0, fitness=340, lut4=2800),
        _entry(1, fitness=320, lut4=2900),  # equal — fails strict
    ]
    w = pick_winner(entries, current_best=320, current_lut=2900,
                    coremark_target=300, lut_target=3000)
    assert w is not None and w["slot"] == 0


def test_pick_winner_missing_lut4_never_wins_tie_break():
    from tools.tournament import pick_winner
    entries = [
        {"slot": 0, "fitness": 300.0, "lut4": None, "outcome": "regression"},
        {"slot": 1, "fitness": 300.0, "lut4": 9000, "outcome": "regression"},
    ]
    assert pick_winner(entries, current_best=282.82)["slot"] == 1


def test_machine_lock_serializes_across_open_files(tmp_path, monkeypatch):
    """Two holders of the formal machine lock never overlap (flock is per
    open-file description, so this models two orchestrator processes)."""
    import threading, time
    from tools.tournament import _machine_lock
    monkeypatch.setenv("AAT_MACHINE_LOCK_DIR", str(tmp_path))
    active, peak = [0], [0]
    guard = threading.Lock()

    def worker():
        with _machine_lock("formal"):
            with guard:
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            time.sleep(0.05)
            with guard:
                active[0] -= 1

    ts = [threading.Thread(target=worker) for _ in range(3)]
    for t in ts: t.start()
    for t in ts: t.join()
    assert peak[0] == 1
    assert (tmp_path / "auto-arch-tournament.formal.lock").exists()


def test_machine_lock_off_and_unlocked_phases(tmp_path, monkeypatch):
    from tools.tournament import _machine_lock
    monkeypatch.setenv("AAT_MACHINE_LOCK_DIR", str(tmp_path))
    with _machine_lock("fpga"):
        pass
    monkeypatch.setenv("AAT_MACHINE_LOCK_DIR", "off")
    with _machine_lock("formal"):
        pass
    assert list(tmp_path.iterdir()) == []


import tools.tournament as tournament


def _stub_slot_pipeline(monkeypatch, tmp_path, fpga_result):
    """run_slot with every agent and gate stubbed; returns the list of
    worktree ids destroy_worktree was called with."""
    import contextlib
    import tools.agents.implement as implement
    import tools.eval.cosim as cosim
    import tools.eval.formal as formal
    import tools.eval.fpga as fpga
    import tools.eval.rvfi_lint as rvfi_lint
    import tools.orchestrator as orch
    import tools.sandbox as sandbox
    import tools.worktree as worktree

    destroyed = []
    monkeypatch.setattr(orch, "validate_hypothesis",
                        lambda p: {"id": "hyp-20260929-002-r11s1", "title": "t", "category": "structural"})
    monkeypatch.setattr(orch, "offlimits_changes", lambda *a, **k: [])
    monkeypatch.setattr(orch, "emit_verilog", lambda *a, **k: (True, ""))
    monkeypatch.setattr(worktree, "create_worktree", lambda *a, **k: str(tmp_path))
    monkeypatch.setattr(worktree, "destroy_worktree", lambda wid, **k: destroyed.append(wid))
    monkeypatch.setattr(implement, "run_implementation_agent", lambda *a, **k: True)
    monkeypatch.setattr(sandbox, "take_snapshot", lambda *a, **k: {})
    monkeypatch.setattr(sandbox, "snapshot_changes", lambda *a, **k: [])
    monkeypatch.setattr(sandbox, "purge_ignored_outputs", lambda *a, **k: None)
    monkeypatch.setattr(sandbox, "use_eval_riscv_formal", lambda *a, **k: None)
    monkeypatch.setattr(rvfi_lint, "check_ch0_contract", lambda *a, **k: {"passed": True})
    monkeypatch.setattr(formal, "run_formal", lambda *a, **k: {"passed": True})
    monkeypatch.setattr(cosim, "run_cosim", lambda *a, **k: {"passed": True})
    monkeypatch.setattr(fpga, "run_fpga_eval", lambda *a, **k: fpga_result)
    monkeypatch.setattr(tournament, "phase_gate", lambda phase: contextlib.nullcontext())
    monkeypatch.setattr(tournament, "_capture_slot_diff", lambda *a, **k: "the diff")
    return destroyed


def _run_stubbed_slot():
    return tournament.run_slot(
        slot=1, hyp_id="hyp-20260929-002-r11s1",
        allowed_yaml_ids=["hyp-20260929-002-r11s1"], log_tail=[],
        current_best=100.0, current_lut=None, baseline=12.0,
        fixed_hyp_path="hyp.yaml", targets=None, target="bench")


def test_placement_failed_slot_removes_its_worktree(monkeypatch, tmp_path):
    # Through harness 2.8.0 a design that failed placement kept its worktree
    # and branch in the clone for the rest of the run (V2 2.8.0 campaign,
    # Luna r11s1 and Opus r13s2); the coordinator assumed the slot had
    # removed them, as broken slots do.
    destroyed = _stub_slot_pipeline(
        monkeypatch, tmp_path, {"placement_failed": True, "seeds": [None, None, None]})
    entry = _run_stubbed_slot()
    assert entry["outcome"] == "placement_failed"
    assert entry["_diff"] == "the diff"
    assert destroyed == ["hyp-20260929-002-r11s1"]


def test_broken_slot_removes_its_worktree(monkeypatch, tmp_path):
    destroyed = _stub_slot_pipeline(
        monkeypatch, tmp_path, {"bench_failed": True, "reason": "coremark crc mismatch"})
    entry = _run_stubbed_slot()
    assert entry["outcome"] == "broken"
    assert destroyed == ["hyp-20260929-002-r11s1"]
