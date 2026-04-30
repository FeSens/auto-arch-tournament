"""Two-phase Pareto accept rule for the research-mode loop.

Spec: docs/superpowers/specs/2026-04-28-research-mode-loop-design.md.

Pure functions, no I/O. Designed to be unit-testable without subprocess
or git state. The orchestrator calls accept(old, new, targets) when
deciding whether to merge a hypothesis into the active branch.
"""
from typing import Optional


def _deficit(value: float, target: float, lower_is_better: bool) -> float:
    """Saturating deficit: 0 when value is at-or-past target, negative below.

    For 'higher is better' axes (perf): deficit = min(0, (value - target)/target).
    For 'lower is better' axes (area): deficit = min(0, (target - value)/target).
    """
    if target is None:
        return 0.0
    if lower_is_better:
        raw = (target - value) / target
    else:
        raw = (value - target) / target
    return min(0.0, raw)


def score(perf: Optional[float],
          lut: Optional[float],
          coremark_target: Optional[float],
          lut_target: Optional[float]) -> float:
    """Sum of saturating deficits across the active axes.

    An axis with target=None contributes 0 (axis is unconstrained).
    Result is always <= 0, with 0 meaning "all active axes at-or-past target".
    """
    s = 0.0
    if coremark_target is not None and perf is not None:
        s += _deficit(perf, coremark_target, lower_is_better=False)
    if lut_target is not None and lut is not None:
        s += _deficit(lut, lut_target, lower_is_better=True)
    return s


def both_met(perf: Optional[float],
             lut: Optional[float],
             coremark_target: Optional[float],
             lut_target: Optional[float]) -> bool:
    """True only when BOTH targets are set AND both axes are at/past their targets."""
    if coremark_target is None or lut_target is None:
        return False
    if perf is None or lut is None:
        return False
    return perf >= coremark_target and lut <= lut_target


def _strict_pareto(old, new) -> bool:
    """new strictly dominates old on (perf, lut)?

    Tuples are (perf, lut). Higher perf is better; lower lut is better.
    Strict dominance: at least as good on both, strictly better on one.
    """
    op, ol = old
    np, nl = new
    not_worse = (np >= op) and (nl <= ol)
    strictly_better = (np > op) or (nl < ol)
    return not_worse and strictly_better


def accept(old: tuple,
           new: tuple,
           coremark_target: Optional[float] = None,
           lut_target: Optional[float] = None) -> bool:
    """Accept rule. old/new are (perf, lut) tuples. Either component may be
    None when the corresponding axis is unconstrained.

    Three modes, dispatched by which targets are set:
      - No targets:    pure fitness comparison (today's behavior).
      - One target:    deficit while below; max-axis past target.
      - Two targets:   phase-1 deficit, phase-2 strict Pareto.
    """
    op, ol = old
    np, nl = new

    # No targets → today's behavior (just compare CoreMark).
    if coremark_target is None and lut_target is None:
        return (np or 0) > (op or 0)

    s_old = score(op, ol, coremark_target, lut_target)
    s_new = score(np, nl, coremark_target, lut_target)

    # Phase 1: at least one axis still below target → score must improve.
    if s_new > s_old:
        return True

    # Tie at score=0 with both targets met → strict Pareto on (perf, lut).
    if (s_old == 0.0 and s_new == 0.0
            and both_met(op, ol, coremark_target, lut_target)
            and both_met(np, nl, coremark_target, lut_target)):
        return _strict_pareto((op, ol), (np, nl))

    # Tie at score=0 in single-axis mode (both past the one target) → fall
    # through to plain "improve the targeted axis".
    if (s_old == 0.0 and s_new == 0.0):
        if coremark_target is not None and lut_target is None:
            return (np or 0) > (op or 0)
        if lut_target is not None and coremark_target is None:
            return (nl or 0) < (ol or 0)

    return False
