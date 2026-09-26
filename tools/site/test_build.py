from types import SimpleNamespace

from datetime import date

from tools.site.build import (
    DEFAULT_RESULTS,
    MODEL_RELEASES,
    ModelAgg,
    Rep,
    aggregate,
    chart_release_vs_fitness,
    is_control_model,
    load_reps,
    render_models,
    render_scheduled_models,
)


def test_scheduled_gpt56_field_tracks_partial_and_complete_models():
    html = render_scheduled_models([])
    assert "GPT-5.6 Sol" in html
    assert "GPT-5.6 Terra" in html
    assert "GPT-5.6 Luna" in html
    assert html.count("<td>scheduled") == 4
    assert html.count('<td><span class="mono">high</span></td>') == 3

    aggs = [
        SimpleNamespace(model="gpt-5_6-sol", n_total=1),
        SimpleNamespace(model="gpt-5_6-terra", n_total=3),
    ]
    html = render_scheduled_models(aggs)
    assert "1 of 3 recorded" in html
    assert "GPT-5.6 Sol" in html
    assert "GPT-5.6 Terra" not in html
    assert "GPT-5.6 Luna" in html


def test_scheduled_field_disappears_after_expected_reps_land():
    aggs = [
        SimpleNamespace(model="gpt-5_6-sol", n_total=3),
        SimpleNamespace(model="gpt-5_6-terra", n_total=3),
        SimpleNamespace(model="gpt-5_6-luna", n_total=3),
    ]
    aggs.append(SimpleNamespace(model="gpt-6-astra_max", n_total=3))
    assert render_scheduled_models(aggs) == ""


def test_model_rep_table_renders_exact_lut_count():
    rep = Rep(
        model="gpt-5_6-luna",
        rep=1,
        status="done",
        final_fitness=462.59,
        best_fitness=462.59,
        baseline_fitness=282.82,
        delta_pct=63.56,
        iterations=46,
        accepted=3,
        rejected=20,
        broken=21,
        broken_by_class={},
        wall_clock_sec=17622,
        total_cost_usd=0.0,
        total_tokens_in=0,
        total_tokens_out=0,
        best_lut4=10155,
        best_ff=1990,
        best_fmax_mhz=201.21,
        best_iterations=10,
        best_cycles=4349632,
        best_ipc_coremark=0.000002,
    )
    agg = ModelAgg(
        model=rep.model,
        reps=[rep],
        n_done=1,
        n_total=1,
        fitness_mean=rep.final_fitness,
        fitness_median=rep.final_fitness,
        fitness_std=0.0,
        fitness_best=rep.best_fitness,
        delta_mean=rep.delta_pct,
        delta_best=rep.delta_pct,
        total_cost_usd=0.0,
        broken_by_class_total={},
        best_rep=rep,
    )

    html = render_models([agg], stars=0)
    assert '<td class="num">10,155</td>' in html
    assert '<td class="num">10.2k</td>' not in html


def test_release_chart_covers_every_scored_model_and_renders_labels():
    aggs = aggregate(load_reps(DEFAULT_RESULTS, DEFAULT_RESULTS.parent.parent))
    scored_models = {a.model for a in aggs
                      if a.fitness_best is not None and not is_control_model(a.model)}
    assert scored_models <= MODEL_RELEASES.keys()
    assert all(date.fromisoformat(meta["date"]) for meta in MODEL_RELEASES.values())

    html = chart_release_vs_fitness(aggs)
    assert 'aria-label="Peak HWE fitness by model release date"' in html
    assert "Gemini 3.1 Pro" in html
    assert "GPT-5.6 Terra" in html
    assert "Public model release date" in html
    assert 'stroke-dasharray="7 6"' in html


def test_is_control_model_matches_known_control_and_ablation_arms():
    assert is_control_model("static")
    assert is_control_model("static-foo")
    assert is_control_model("random-mutation")
    assert is_control_model("naive-gpt-5_5_medium")
    assert not is_control_model("gpt-5_5_medium")
    assert not is_control_model("gemini-3_1-pro")


def test_release_chart_skips_control_models_even_with_data():
    static_agg = SimpleNamespace(model="static", fitness_best=300.0)
    scored_agg = SimpleNamespace(model="gemini-3_1-pro", fitness_best=400.0)
    html_with_control = chart_release_vs_fitness([static_agg, scored_agg])
    html_without_control = chart_release_vs_fitness([scored_agg])
    assert html_with_control == html_without_control


def test_astra_scheduled_for_three_reps_at_max():
    html = render_scheduled_models([])
    assert "GPT-6 Astra max" in html
    assert "codex:gpt-6-astra" in html
    assert '<td><span class="mono">max</span></td>' in html
    assert "scheduled · 3 planned reps</td>" in html
    html = render_scheduled_models([SimpleNamespace(model="gpt-6-astra_max", n_total=1)])
    assert "GPT-6 Astra max" in html
    assert "1 of 3 recorded" in html
    html = render_scheduled_models([SimpleNamespace(model="gpt-6-astra_max", n_total=3)])
    assert "GPT-6 Astra max" not in html


def test_site_renders_opus_row_with_note_and_caveats(tmp_path):
    # A stand-in for the row the runner appends when the run ends. The
    # numbers are placeholders; only the rendering path is under test.
    import json

    from tools.site.build import (
        DEFAULT_RESULTS, aggregate, load_reps, render_data, render_index,
        render_models,
    )

    row = {"model": "claude-opus-5_5_xhigh", "rep": 1, "status": "done",
           "final_fitness": 900.0, "best_fitness": 900.0,
           "baseline_fitness": 282.82, "delta_pct": 218.2, "iterations": 46,
           "accepted": 9, "rejected": 14, "broken": 23,
           "broken_by_class": {"hypothesis_gen_failed": 22, "formal_failed": 1},
           "wall_clock_sec": 60000, "total_cost_usd": 0.0,
           "api_equivalent_cost_usd": 100.0, "total_tokens_in": 1,
           "total_tokens_out": 1, "best_lut4": 2826, "best_ff": 2000,
           "best_fmax_mhz": 285.71, "best_iterations": 10,
           "best_cycles": 3000000, "best_ipc_coremark": 2e-06}
    results = tmp_path / "results.jsonl"
    # Drop the real Opus row (if published) so only the stand-in is counted.
    kept = [l for l in DEFAULT_RESULTS.read_text().splitlines()
            if l.strip() and json.loads(l).get("model") != row["model"]]
    results.write_text("\n".join(kept) + "\n" + json.dumps(row) + "\n")
    reps = load_reps(results, tmp_path)  # no journals under tmp_path
    aggs = aggregate(reps)

    models_html = render_models(aggs, stars=0)
    assert 'id="claude-opus-5_5_xhigh"' in models_html
    assert "Claude Code 2.1.282" in models_html
    assert "<code>hypothesis_gen_failed</code>×22" in models_html

    index_html = render_index(aggs, reps, stars=0)
    assert "<code>claude-opus-5_5_xhigh</code>" in index_html
    assert "(one repetition, n=1; untested)" in index_html

    assert "bench/claude-opus-5_5_xhigh/rep1/summary.json" in render_data(reps, stars=0)


def test_random_mutation_hidden_from_site():
    from tools.site.build import (DEFAULT_RESULTS, aggregate, load_reps,
                                  render_data, render_index, render_models)
    assert "random-mutation" in DEFAULT_RESULTS.read_text()  # data kept
    reps = load_reps(DEFAULT_RESULTS, DEFAULT_RESULTS.parent.parent)
    assert all(r.model != "random-mutation" for r in reps)
    aggs = aggregate(reps)
    for html in (render_index(aggs, reps, 0), render_models(aggs, 0),
                 render_data(reps, 0)):
        assert "random-mutation" not in html
