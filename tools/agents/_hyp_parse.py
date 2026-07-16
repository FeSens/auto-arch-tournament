"""Shared hypothesis-id parser for mechanical (no-LLM) agents.

Both static_agent.py and random_agent.py need to recover the
orchestrator's pre-allocated hypothesis id from the prompt text they're
handed as argv[0]. Extracted here after a production incident: a bare
leftmost regex search over the whole prompt grabs a STALE id on
tournament rounds >= 2, because the prompt's history section quotes
prior rounds' ids before the authoritative id clause
(tools/agents/hypothesis.py's `_build_prompt` emits "Use exactly this
hypothesis ID: <id>" near the end of the prompt, id_clause). The static
agent's original bare-leftmost-search implementation hit this; the
random agent's implementation was already hardened (marker-anchored,
rfind-based) and is moved here verbatim so both agents share one fix.
"""
from __future__ import annotations

import re

_HYP_ID = re.compile(r"\bhyp-\d{8}-\d{3}-r\d+s\d+\b")
_ID_MARKER = "Use exactly this hypothesis ID:"


def parse_hyp_id(prompt: str) -> str | None:
    # Prefer the authoritative id clause hypothesis.py emits ("Use exactly
    # this hypothesis ID: <id>"). Round >= 2 prompts also quote prior
    # rounds' ids in the history section, which sits BEFORE this clause,
    # so use rfind() to grab the LAST marker occurrence. If the marker is
    # present but malformed (no valid id token follows), fail loudly by
    # returning None. Only fall back to leftmost search for older prompt
    # shapes without the marker at all.
    marker_idx = prompt.rfind(_ID_MARKER)
    if marker_idx != -1:
        m = _HYP_ID.search(prompt, marker_idx + len(_ID_MARKER))
        if m:
            return m.group(0)
        else:
            # Marker present but no valid id token follows: fail loudly
            return None
    # Marker absent: fall back to leftmost search
    m = _HYP_ID.search(prompt)
    return m.group(0) if m else None
