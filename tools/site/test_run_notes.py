from types import SimpleNamespace

from tools.site.run_notes import (
    RUN_NOTES,
    leader_sample_caveat,
    render_run_note,
    render_single_rep_caveat,
)


def _agg(model, n_total, best=400.0):
    return SimpleNamespace(model=model, n_total=n_total, fitness_best=best)


def test_opus_note_labels_single_rep_and_links_readme():
    html = render_run_note(_agg("claude-opus-5_5_xhigh", 1))
    assert "Claude Code 2.1.282" in html
    assert '<span class="mono">xhigh</span>' in html
    assert "n=1" in html
    assert "untested" in html
    assert "bench/claude-opus-5_5_xhigh/README.md" in html


def test_opus_note_carries_every_operator_caveat():
    html = render_run_note(_agg("claude-opus-5_5_xhigh", 1))
    for phrase in (
        "second launch",               # launch history
        "not scored",                  # launch 1 excluded
        "20-minute",                   # hypothesis-agent timeout
        "ready signals tied high",     # stall-only hardware
        "unmeasured",                  # its magnitude
        "divider",                     # r10s0 slower divider
        "RVFI",                        # r12s1 rvfi_order
        "LUT-RAM",                     # lut4 column exclusion
        "not measured zero spend",     # OAuth cost
        "lower bound",                 # killed-session output tokens
    ):
        assert phrase in html, phrase
    assert "\u2014" not in html  # no em-dash in user-facing text


def test_note_counts_reps_when_more_land():
    html = render_run_note(_agg("claude-opus-5_5_xhigh", 3))
    assert "3 independent repetitions recorded" in html
    assert "n=1" not in html


def test_unknown_model_has_no_note():
    assert render_run_note(_agg("gpt-5_5_high", 3)) == ""
    assert set(RUN_NOTES) == {"claude-opus-5_5_xhigh"}


def test_single_rep_caveat_lists_only_new_scored_single_rep_models():
    aggs = [
        _agg("claude-opus-5_5_xhigh", 1),
        _agg("gpt-6-sol_xhigh", 1),
        _agg("gpt-5_5_high", 3),
        _agg("random-mutation", 1),         # control arm
        _agg("gemini-3_5-flash", 1, None),  # no scored fitness
    ]
    html = render_single_rep_caveat(aggs)
    assert "<code>claude-opus-5_5_xhigh</code>" in html
    assert "gpt-6-sol_xhigh" not in html  # published before run notes existed
    assert "gpt-5_5_high" not in html
    assert "random-mutation" not in html
    assert "gemini-3_5-flash" not in html
    assert "untested" in html
    assert render_single_rep_caveat([_agg("gpt-5_5_high", 3)]) == ""


def test_leader_caveat_only_for_single_rep_leader():
    assert "n=1" in leader_sample_caveat(_agg("claude-opus-5_5_xhigh", 1))
    assert leader_sample_caveat(_agg("gpt-5_5_high", 3)) == ""
    assert leader_sample_caveat(None) == ""

