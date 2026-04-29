"""Tests for hypothesis-prompt augmentation in research mode."""
import json
from pathlib import Path

from tools.agents.hypothesis import _build_prompt, _recent_outcomes, _lessons_block


def _stub_args():
    """Minimum args _build_prompt needs to run."""
    return dict(
        log_tail=[],
        current_fitness=300.0,
        baseline_fitness=300.0,
        hyp_id="hyp-test-001-r1s0",
    )


def test_prompt_omits_targets_block_when_no_targets():
    p = _build_prompt(**_stub_args())
    assert "Optimization targets" not in p


def test_prompt_includes_dual_target_block():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 300, "lut": 3000},
        current_state={"coremark": 320, "lut": 3300},
    )
    assert "Optimization targets" in p
    assert "CoreMark = 300 iter/s" in p
    assert "LUT4     = 3000" in p
    assert "CoreMark   = 320 iter/s" in p
    assert "LUT4       = 3300" in p
    assert "deficit-driven in phase 1" in p
    assert "strict Pareto-dominance in phase 2" in p


def test_prompt_includes_single_target_perf_block():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 370},
        current_state={"coremark": 320},
    )
    assert "Optimization targets" in p
    assert "CoreMark = 370 iter/s" in p
    assert "LUT4" not in p.split("Optimization targets")[1].split("Accept rule")[0]
    assert "pull CoreMark toward the target" in p


def test_prompt_target_met_status_when_above():
    p = _build_prompt(
        **_stub_args(),
        targets={"coremark": 300, "lut": 3000},
        current_state={"coremark": 320, "lut": 2900},
    )
    assert "target met" in p


def test_prompt_no_longer_inlines_full_jsonl():
    """The whole point of the redesign: log.jsonl is no longer dumped
    into the prompt. The 30-entry payload below would have shown up
    verbatim under the old `## Recent Experiment Log` block; now only
    the last 5 should appear and only as a one-line summary each."""
    log_tail = [
        {
            "id": f"hyp-old-{i:03d}",
            "title": f"old-title-{i}",
            "outcome": "regression",
            "delta_pct": -1.5,
            "category": "structural",
            "implementation_notes": "secret-string-that-must-not-leak",
        }
        for i in range(30)
    ]
    p = _build_prompt(
        **{**_stub_args(), "log_tail": log_tail},
    )
    # Old behavior: every entry json.dumps'd into the prompt.
    assert json.dumps(log_tail[0]) not in p
    # Implementation notes should NOT be inlined (the whole entry shouldn't be).
    assert "secret-string-that-must-not-leak" not in p
    # Old section header is gone.
    assert "Recent Experiment Log" not in p
    # New summary is present.
    assert "Recent outcomes (last 5)" in p
    # Only the last 5 ids appear in the summary block.
    assert "hyp-old-029" in p
    assert "hyp-old-025" in p
    assert "hyp-old-024" not in p  # outside the 5-window


def test_prompt_includes_lessons_pointer_block():
    """Even with no LESSONS.md and no target, the prompt must point at
    log.jsonl + LESSONS.md as Read/Grep targets — the agent can't be
    expected to discover them."""
    p = _build_prompt(**{**_stub_args(), "target": "rv32i"})
    assert "How to dig deeper" in p
    assert "cores/rv32i/experiments/log.jsonl" in p
    assert "LESSONS.md" in p


def test_recent_outcomes_empty():
    assert "no experiments yet" in _recent_outcomes([])


def test_recent_outcomes_truncates_to_n():
    log = [
        {"id": f"e{i}", "title": f"t{i}", "outcome": "regression", "delta_pct": 0.0}
        for i in range(10)
    ]
    out = _recent_outcomes(log, n=3)
    assert "e9" in out and "e8" in out and "e7" in out
    assert "e6" not in out


def test_lessons_block_no_target():
    assert "lessons unavailable" in _lessons_block(None)


def test_lessons_block_inlines_small_file(tmp_path, monkeypatch):
    # _lessons_block resolves cores/<target>/LESSONS.md relative to cwd,
    # so chdir into a sandbox with a fixture file.
    monkeypatch.chdir(tmp_path)
    (tmp_path / "cores" / "foo").mkdir(parents=True)
    (tmp_path / "cores" / "foo" / "LESSONS.md").write_text(
        "- 2026-04-29 hyp-test (regression, -1.0%): example lesson\n"
    )
    out = _lessons_block("foo")
    assert "example lesson" in out


def test_lessons_block_pointer_when_large(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "cores" / "foo").mkdir(parents=True)
    big = "\n".join(f"- line {i}" for i in range(500))
    (tmp_path / "cores" / "foo" / "LESSONS.md").write_text(big + "\n")
    out = _lessons_block("foo")
    assert "large" in out.lower()
    assert "Read cores/foo/LESSONS.md" in out
    # Body must NOT be inlined — the whole point of the pointer mode.
    assert "line 250" not in out
