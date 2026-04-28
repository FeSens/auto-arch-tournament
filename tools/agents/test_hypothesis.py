"""Tests for hypothesis-prompt augmentation in research mode."""
from tools.agents.hypothesis import _build_prompt


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
