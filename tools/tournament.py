"""Speculative-tournament orchestration helpers.

The orchestrator delegates to this module for per-round logic so the pure
helpers (ID allocation, diversity rotation, winner picking) can be unit
tested without claude or the FPGA toolchain.
"""
from __future__ import annotations

import datetime
from typing import Optional

# The hypothesis schema's `category` enum, in the order the brief specifies.
# Slot index modulo len(CATEGORIES) picks one — slot 5+ wraps. This keeps
# round diversity deterministic while still letting the agent pick a
# different angle for each slot.
CATEGORIES: list[str] = [
    "micro_opt",
    "structural",
    "predictor",
    "memory",
    "extension",
]


def category_for_slot(slot: int) -> str:
    """Return the diversity category for a slot index, wrapping at 5."""
    return CATEGORIES[slot % len(CATEGORIES)]


def allocate_round_ids(
    round_id: int,
    tournament_size: int,
    today: Optional[str] = None,
    first_seq: int = 1,
) -> list[str]:
    """Pre-allocate `tournament_size` hypothesis IDs for a round.

    IDs follow `hyp-YYYYMMDD-NNN-rRsS` so they're unique across slots
    AND back-compat with the legacy `hyp-YYYYMMDD-NNN` shape (the
    schema regex now accepts both). Pre-allocation is the fix for the
    `_next_id` race: two slots calling it concurrently would otherwise
    pick the same NNN.
    """
    if today is None:
        today = datetime.date.today().strftime("%Y%m%d")
    return [
        f"hyp-{today}-{(first_seq + s):03d}-r{round_id}s{s}"
        for s in range(tournament_size)
    ]


def pick_winner(entries: list[dict], current_best: float) -> Optional[dict]:
    """Return the round's winner: highest-fitness slot that beat current_best.

    Slots without a fitness number (broken / placement_failed / cosim_failed)
    are ignored. Returns None if no slot cleared the bar — in that case the
    round produces no accept and the cumulative champion stays where it was.
    """
    candidates = [
        e for e in entries
        if isinstance(e.get("fitness"), (int, float))
        and e["fitness"] > current_best
    ]
    if not candidates:
        return None
    # Tie-break: highest fitness, lowest slot wins. Without this, equal-fitness
    # slots would resolve in caller-supplied order — which today is slot-sorted
    # but shouldn't be a load-bearing contract of the helper.
    return max(candidates, key=lambda e: (e["fitness"], -e["slot"]))
