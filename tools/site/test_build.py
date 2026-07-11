from types import SimpleNamespace

from datetime import date

from tools.site.build import (
    DEFAULT_RESULTS,
    MODEL_RELEASES,
    ModelAgg,
    Rep,
    aggregate,
    chart_release_vs_fitness,
    load_reps,
    render_models,
    render_scheduled_models,
)


def test_scheduled_gpt56_field_tracks_partial_and_complete_models():
    html = render_scheduled_models([])
    assert "GPT-5.6 Sol" in html
    assert "GPT-5.6 Terra" in html
    assert "GPT-5.6 Luna" in html
    assert html.count("scheduled") == 3
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


def test_scheduled_gpt56_field_disappears_after_all_reps_land():
    aggs = [
        SimpleNamespace(model="gpt-5_6-sol", n_total=3),
        SimpleNamespace(model="gpt-5_6-terra", n_total=3),
        SimpleNamespace(model="gpt-5_6-luna", n_total=3),
    ]
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
    scored_models = {a.model for a in aggs if a.fitness_best is not None}
    assert scored_models <= MODEL_RELEASES.keys()
    assert all(date.fromisoformat(meta["date"]) for meta in MODEL_RELEASES.values())

    html = chart_release_vs_fitness(aggs)
    assert 'aria-label="Peak HWE fitness by model release date"' in html
    assert "Gemini 3.1 Pro" in html
    assert "GPT-5.6 Terra" in html
    assert "Public model release date" in html
    assert 'stroke-dasharray="7 6"' in html
