"""Unit tests for tools/tournament.py pure helpers (no claude / no FPGA)."""
from tools.tournament import (
    allocate_round_ids,
    category_for_slot,
    pick_winner,
)


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


def test_phase_gate_serializes_under_capacity_one():
    """Two threads contending on the formal gate must not overlap."""
    import threading, time
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
