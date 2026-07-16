"""Tests for the static (no-LLM) control agent.

Regression coverage for the production incident where
`_hyp_id_from_prompt`'s bare leftmost regex search grabbed a STALE
hypothesis id quoted in a round >= 2 prompt's history section, instead
of the id in the authoritative "Use exactly this hypothesis ID: <id>"
clause that hypothesis.py's `_build_prompt` emits near the end of the
prompt. random_agent.py's `_hyp_id` was already hardened against this
(marker-anchored via rfind); static_agent.py now shares that same
logic via tools/agents/_hyp_parse.parse_hyp_id.
"""
from pathlib import Path

from tools.agents import static_agent as sa
from tools.agents._hyp_parse import parse_hyp_id


def test_hyp_id_uses_authoritative_clause_not_leftmost_match():
    # Round >= 2 prompt shape: the history section quotes a stale prior
    # round's id before the authoritative id clause appears later.
    prompt = (
        "## Recent outcomes (last 5)\n"
        "- hyp-20260716-001-r1s0: rejected, formal_failed: ill check\n"
        "\n"
        "## Instructions\n"
        "Use exactly this hypothesis ID: hyp-20260716-001-r2s1\n"
        "\n"
        "## Required YAML structure\n"
    )
    assert sa._hyp_id_from_prompt(prompt) == "hyp-20260716-001-r2s1"


def test_hyp_id_falls_back_to_leftmost_when_no_marker():
    # Older prompt shapes without the authoritative clause: preserve the
    # previous leftmost-match behavior.
    prompt = "Hypothesis: hyp-20260101-001-r1s0\nSome other text.\n"
    assert sa._hyp_id_from_prompt(prompt) == "hyp-20260101-001-r1s0"


def test_hyp_id_marker_present_but_malformed_returns_none():
    # Marker is present but no valid id token follows.
    # Should return None (fail loudly), not fall back to leftmost search.
    prompt = (
        "## History\n"
        "Use exactly this hypothesis ID: hyp-20260716-001-r1s0\n"
        "\n"
        "## Instructions\n"
        "Use exactly this hypothesis ID: (no valid id here)\n"
    )
    assert sa._hyp_id_from_prompt(prompt) is None


def test_write_static_hypothesis_skips_write_on_none(tmp_path, monkeypatch, capsys):
    # Marker present but malformed -> _hyp_id_from_prompt returns None ->
    # _write_static_hypothesis must hit its fail-fast branch and write
    # nothing, rather than fall back to a stale/leftmost id and produce a
    # YAML at a non-whitelisted path.
    monkeypatch.chdir(tmp_path)
    prompt = (
        "## Hypothesis schema\n"
        "TARGET CORE: cores/bench/\n"
        "## History\n"
        "Use exactly this hypothesis ID: hyp-20260716-001-r1s0\n"
        "\n"
        "## Instructions\n"
        "Use exactly this hypothesis ID: (no valid id here)\n"
    )
    sa._write_static_hypothesis(prompt)
    hyp_dir = tmp_path / "cores" / "bench" / "experiments" / "hypotheses"
    assert not hyp_dir.exists() or list(hyp_dir.glob("*.yaml")) == []
    err = capsys.readouterr().err
    assert "no hypothesis id found in prompt; skipping" in err


def test_hyp_id_from_prompt_delegates_to_shared_parser():
    # static_agent's function must be a thin wrapper around the shared
    # helper, not a re-implementation that can drift out of sync.
    prompt = (
        "## Recent outcomes\n"
        "Use exactly this hypothesis ID: hyp-20260716-001-r1s0\n"
        "\n"
        "## Instructions\n"
        "Use exactly this hypothesis ID: hyp-20260716-001-r2s1\n"
    )
    assert sa._hyp_id_from_prompt(prompt) == parse_hyp_id(prompt)


# ----- Integration regression test: real hypothesis.py prompt shape -----

def test_parse_hyp_id_on_real_round2_prompt(tmp_path, monkeypatch):
    """Build an actual round-2 prompt via hypothesis.py's real prompt
    builder (history_section + id_clause), with a prior-round outcome
    quoting a stale id ahead of the authoritative id clause, and confirm
    parse_hyp_id recovers the newly ALLOCATED id, not the history id.

    This is the test that would have caught both the static_agent bug
    (bare leftmost search) and would catch any future regression where
    hypothesis.py's prompt shape changes such that the id clause no
    longer anchors correctly.
    """
    from tools.agents.hypothesis import _build_prompt

    monkeypatch.chdir(tmp_path)
    (tmp_path / "ARCHITECTURE.md").write_text("arch doc\n")

    stale_round1_id = "hyp-20260715-001-r1s0"
    allocated_round2_id = "hyp-20260715-001-r2s1"

    log_tail = [{
        "id": stale_round1_id,
        "title": "prior round attempt",
        "outcome": "rejected",
        "delta_pct": -1.5,
        "category": "micro_opt",
    }]

    prompt = _build_prompt(
        log_tail=log_tail,
        current_fitness=300.0,
        baseline_fitness=300.0,
        hyp_id=allocated_round2_id,
    )

    # Sanity: the prompt really does quote the stale id in its history
    # section BEFORE the authoritative clause (the exact shape that broke
    # the bare leftmost regex in production).
    assert stale_round1_id in prompt
    assert prompt.index(stale_round1_id) < prompt.rindex(
        "Use exactly this hypothesis ID:")

    assert parse_hyp_id(prompt) == allocated_round2_id
    assert parse_hyp_id(prompt) != stale_round1_id
