"""Tests for the dual-target Pareto accept rule.
Cases mirror the worked examples in
docs/superpowers/specs/2026-04-28-research-mode-loop-design.md.
"""
from tools.accept_rule import score, both_met, accept


# ── score() — saturating deficit per axis ──────────────────────────────────
def test_score_below_both_targets():
    # Targets 300, 3000. Design (200, 5000):
    #   deficit_perf = (200 - 300) / 300 = -0.333...
    #   deficit_area = (3000 - 5000) / 3000 = -0.666...
    s = score(200, 5000, 300, 3000)
    assert abs(s - (-1.0)) < 1e-6


def test_score_perf_above_target_saturates_to_zero():
    # 600 perf is past the 300 target; deficit_perf saturates to 0.
    # Area still under-target contributes its share.
    s = score(600, 4000, 300, 3000)
    assert abs(s - (-1/3)) < 1e-6


def test_score_both_met_is_zero():
    s = score(320, 2900, 300, 3000)
    assert s == 0.0


def test_score_single_axis_perf():
    # No LUT target → only the perf axis contributes.
    s = score(200, None, 300, None)
    assert abs(s - (-1/3)) < 1e-6


def test_score_no_targets_is_zero():
    # No targets → degenerate to today's "ignore deficit" baseline.
    assert score(200, 5000, None, None) == 0.0


# ── both_met() — phase boundary ────────────────────────────────────────────
def test_both_met_true_at_or_past_targets():
    assert both_met(300, 3000, 300, 3000) is True
    assert both_met(400, 2500, 300, 3000) is True


def test_both_met_false_when_either_axis_short():
    assert both_met(299, 3000, 300, 3000) is False
    assert both_met(300, 3001, 300, 3000) is False


def test_both_met_only_with_dual_targets():
    # Single-axis targets → "both met" is undefined; return False so the
    # accept rule falls through to the single-axis path.
    assert both_met(400, 2000, 300, None) is False


# ── accept() — phase 1 ────────────────────────────────────────────────────
def test_accept_phase1_recovers_perf_at_area_cost_when_far_from_target():
    # Spec example 1: (200, 5000) → (290, 5500).
    # Old score = -1.000, new = -0.867 → accept.
    assert accept(old=(200, 5000), new=(290, 5500),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase1_rejects_paying_area_for_past_target_perf():
    # Spec example 2: (330, 3300) → (600, 4000).
    # perf already past target → free credit; area got worse → score drops.
    assert accept(old=(330, 3300), new=(600, 4000),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase1_accepts_hitting_area_target_with_small_perf_loss():
    # (310, 3300) → (290, 3000). Hits area target; small perf cost.
    assert accept(old=(310, 3300), new=(290, 3000),
                  coremark_target=300, lut_target=3000) is True


# ── accept() — phase 2 (both already at/past target) ──────────────────────
def test_accept_phase2_accepts_strict_pareto_perf_only():
    assert accept(old=(320, 2900), new=(340, 2900),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase2_accepts_strict_pareto_area_only():
    assert accept(old=(320, 2900), new=(320, 2700),
                  coremark_target=300, lut_target=3000) is True


def test_accept_phase2_rejects_perf_paid_with_area():
    assert accept(old=(320, 2900), new=(340, 2950),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase2_rejects_no_change():
    assert accept(old=(320, 2900), new=(320, 2900),
                  coremark_target=300, lut_target=3000) is False


def test_accept_phase2_to_phase1_regression_rejected():
    # (320, 2900) is phase 2. (350, 3050) regresses past area target →
    # phase 1 with negative score → reject.
    assert accept(old=(320, 2900), new=(350, 3050),
                  coremark_target=300, lut_target=3000) is False


# ── accept() — single-axis aspiration ─────────────────────────────────────
def test_accept_single_axis_below_target_must_close_deficit():
    # Target 370. Old 200 (deficit -.46), new 280 (deficit -.243). Accept.
    assert accept(old=(200, None), new=(280, None),
                  coremark_target=370, lut_target=None) is True


def test_accept_single_axis_above_target_max_coremark():
    # Both past target → fall through to plain "fitness > champion".
    assert accept(old=(380, None), new=(400, None),
                  coremark_target=370, lut_target=None) is True
    assert accept(old=(400, None), new=(380, None),
                  coremark_target=370, lut_target=None) is False


def test_accept_single_axis_regression_below_target_rejected():
    # 380 → 350: 380 was past target (score 0); 350 is below (score -0.054).
    assert accept(old=(380, None), new=(350, None),
                  coremark_target=370, lut_target=None) is False


# ── accept() — no targets (today's behavior) ──────────────────────────────
def test_accept_no_targets_pure_fitness_compare():
    assert accept(old=(300, 5000), new=(310, 5500),
                  coremark_target=None, lut_target=None) is True
    assert accept(old=(310, 5500), new=(300, 5000),
                  coremark_target=None, lut_target=None) is False


def test_accept_no_targets_equal_fitness_rejected():
    assert accept(old=(300, 5000), new=(300, 4000),
                  coremark_target=None, lut_target=None) is False
