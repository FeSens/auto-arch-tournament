"""Render the benchmark leaderboard.

Reads bench/results.jsonl, aggregates per model (mean ± std final
fitness across reps, best-of-J fitness, iterations-to-best, pass-rate,
total $ cost, mean wall-clock per iteration), and writes:
  - bench/LEADERBOARD.md  (human-readable markdown table)
  - bench/leaderboard.csv (machine-readable)

Usage:
    python -m tools.bench.report
    python -m tools.bench.report --results bench/results.jsonl --out bench/
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


HERE = Path(__file__).parent
REPO_ROOT = HERE.parent.parent
DEFAULT_RESULTS = REPO_ROOT / "bench" / "results.jsonl"
DEFAULT_OUT_DIR = REPO_ROOT / "bench"


@dataclass
class RepResult:
    model: str
    rep: int
    status: str
    final_fitness: Optional[float]
    best_fitness: Optional[float]
    best_round: Optional[int]
    baseline_fitness: Optional[float]
    iterations: int
    accepted: int
    rejected: int
    broken: int
    delta_pct: Optional[float]
    wall_clock_sec: int
    total_cost_usd: float
    total_tokens_in: int
    total_tokens_out: int
    broken_by_class: dict[str, int]
    # FPGA-side detail of the best-fitness entry in this rep. None when
    # no fitness was achieved (every iteration broken/regressed).
    best_lut4: Optional[int]
    best_ff: Optional[int]
    best_fmax_mhz: Optional[float]
    best_iterations: Optional[int]
    best_cycles: Optional[int]
    best_ipc_coremark: Optional[float]


def load_results(path: Path) -> list[RepResult]:
    if not path.is_file():
        return []
    out: list[RepResult] = []
    for raw in path.read_text().splitlines():
        s = raw.strip()
        if not s:
            continue
        try:
            row = json.loads(s)
        except json.JSONDecodeError:
            continue
        out.append(RepResult(
            model=row.get("model", "?"),
            rep=int(row.get("rep", 0)),
            status=row.get("status", "?"),
            final_fitness=row.get("final_fitness"),
            best_fitness=row.get("best_fitness"),
            best_round=row.get("best_round"),
            baseline_fitness=row.get("baseline_fitness"),
            iterations=int(row.get("iterations") or 0),
            accepted=int(row.get("accepted") or 0),
            rejected=int(row.get("rejected") or 0),
            broken=int(row.get("broken") or 0),
            delta_pct=row.get("delta_pct"),
            wall_clock_sec=int(row.get("wall_clock_sec") or 0),
            total_cost_usd=float(row.get("total_cost_usd") or 0.0),
            total_tokens_in=int(row.get("total_tokens_in") or 0),
            total_tokens_out=int(row.get("total_tokens_out") or 0),
            broken_by_class=dict(row.get("broken_by_class") or {}),
            best_lut4=row.get("best_lut4"),
            best_ff=row.get("best_ff"),
            best_fmax_mhz=row.get("best_fmax_mhz"),
            best_iterations=row.get("best_iterations"),
            best_cycles=row.get("best_cycles"),
            best_ipc_coremark=row.get("best_ipc_coremark"),
        ))
    return out


@dataclass
class ModelAgg:
    model: str
    n_reps_done: int
    n_reps_failed: int
    fitness_mean: Optional[float]
    fitness_std: Optional[float]
    fitness_best: Optional[float]
    iters_to_best_mean: Optional[float]
    pass_rate: Optional[float]
    total_cost_usd: float
    mean_wall_clock_per_iter_sec: Optional[float]
    total_tokens_in: int
    total_tokens_out: int
    # Per-rep counts of each outcome class — averaged across the reps for
    # this model. Reflect what fraction of a rep's iterations landed in
    # each bucket (improvement / regression / broken) so the leaderboard
    # surfaces "this model's hypotheses fail a lot" beyond just pass-rate.
    accepted_mean: Optional[float]
    rejected_mean: Optional[float]
    broken_mean: Optional[float]
    # Aggregate of the broken_by_class dicts across all reps of this model.
    # Keys are broken-class names (formal_failed, hypothesis_gen_failed,
    # placement_failed, implementation_compile_failed, ...); values are
    # the total occurrences. Used by render_failure_modes_section to
    # explain *why* a model's broken count is what it is.
    broken_by_class_total: dict[str, int]
    # FPGA-side detail of this model's best rep (the one whose best_fitness
    # = fitness_best). LUT4 and Fmax are the headline microarch numbers
    # — fitness is computed from Fmax × IPC, but the area-vs-frequency
    # tradeoff a model picks is invisible at the fitness-only level.
    best_rep_lut4: Optional[int]
    best_rep_ff: Optional[int]
    best_rep_fmax_mhz: Optional[float]
    best_rep_iterations: Optional[int]
    best_rep_cycles: Optional[int]
    best_rep_ipc_coremark: Optional[float]


def _safe_mean(xs: list[float]) -> Optional[float]:
    return statistics.fmean(xs) if xs else None


def _safe_std(xs: list[float]) -> Optional[float]:
    return statistics.pstdev(xs) if len(xs) >= 2 else (0.0 if xs else None)


def aggregate(rows: list[RepResult]) -> list[ModelAgg]:
    by_model: dict[str, list[RepResult]] = {}
    for r in rows:
        by_model.setdefault(r.model, []).append(r)

    out: list[ModelAgg] = []
    for model, reps in by_model.items():
        # Reps with status="done" but no fitness number ran the harness
        # cleanly but produced a broken iteration (model failed to write
        # a valid hypothesis, RTL didn't pass eval gates, etc.). Count
        # them as "did not produce a fitness number" rather than dropping
        # them silently — they're not the same as harness-side failures
        # but they didn't yield a result either.
        done = [r for r in reps if r.status == "done" and r.final_fitness is not None]
        failed = [r for r in reps if r.status != "done" or r.final_fitness is None]
        fits = [r.final_fitness for r in done if r.final_fitness is not None]
        bests = [r.best_fitness for r in done if r.best_fitness is not None]
        iters_to_best = [r.best_round for r in done if r.best_round is not None]
        pass_rates = []
        for r in done:
            if r.iterations:
                pass_rates.append(r.accepted / r.iterations)
        wall_per_iter = []
        for r in done:
            if r.iterations:
                wall_per_iter.append(r.wall_clock_sec / r.iterations)

        # Per-rep outcome counts, averaged across this model's reps. Use
        # all reps (incl. status!=done) so a model that crashed mid-rep
        # still gets credit for whatever outcomes it produced.
        accepted_counts = [float(r.accepted) for r in reps if r.iterations]
        rejected_counts = [float(r.rejected) for r in reps if r.iterations]
        broken_counts   = [float(r.broken)   for r in reps if r.iterations]
        broken_by_class_total: dict[str, int] = {}
        for r in reps:
            for cls, n in (r.broken_by_class or {}).items():
                broken_by_class_total[cls] = broken_by_class_total.get(cls, 0) + int(n)

        # Identify the rep that achieved this model's fitness_best —
        # its LUT4/Fmax/IPC are what we surface as the model's "best
        # design" microarch numbers.
        best_rep = max(done, key=lambda r: r.best_fitness or -math.inf) if done else None

        out.append(ModelAgg(
            model=model,
            n_reps_done=len(done),
            n_reps_failed=len(failed),
            fitness_mean=_safe_mean(fits) if fits else None,
            fitness_std=_safe_std(fits) if fits else None,
            fitness_best=max(bests) if bests else None,
            iters_to_best_mean=_safe_mean([float(x) for x in iters_to_best])
                if iters_to_best else None,
            pass_rate=_safe_mean(pass_rates) if pass_rates else None,
            total_cost_usd=sum(r.total_cost_usd for r in reps),
            mean_wall_clock_per_iter_sec=_safe_mean(wall_per_iter) if wall_per_iter else None,
            total_tokens_in=sum(r.total_tokens_in for r in reps),
            total_tokens_out=sum(r.total_tokens_out for r in reps),
            accepted_mean=_safe_mean(accepted_counts) if accepted_counts else None,
            rejected_mean=_safe_mean(rejected_counts) if rejected_counts else None,
            broken_mean=_safe_mean(broken_counts) if broken_counts else None,
            broken_by_class_total=broken_by_class_total,
            best_rep_lut4=best_rep.best_lut4 if best_rep else None,
            best_rep_ff=best_rep.best_ff if best_rep else None,
            best_rep_fmax_mhz=best_rep.best_fmax_mhz if best_rep else None,
            best_rep_iterations=best_rep.best_iterations if best_rep else None,
            best_rep_cycles=best_rep.best_cycles if best_rep else None,
            best_rep_ipc_coremark=best_rep.best_ipc_coremark if best_rep else None,
        ))

    out.sort(key=lambda a: (-(a.fitness_mean if a.fitness_mean is not None else -math.inf), a.model))
    return out


def fmt_fitness(mean: Optional[float], std: Optional[float]) -> str:
    if mean is None:
        return "—"
    if std is None:
        return f"{mean:.1f}"
    return f"{mean:.1f} ± {std:.1f}"


def fmt_pct(p: Optional[float]) -> str:
    return "—" if p is None else f"{p * 100:.0f}%"


def fmt_num(x: Optional[float], fmt: str = ".1f") -> str:
    return "—" if x is None else format(x, fmt)


def wilcoxon_signed_rank(diffs: list[float]) -> tuple[Optional[float], Optional[float]]:
    """Two-sided Wilcoxon signed-rank test (no-scipy implementation).

    `diffs` is a list of paired (treatment − control) differences,
    one per shared rep. Zeros are excluded (Wilcoxon convention).
    Returns (W, p_two_sided). p is None when n < 5 — at that point the
    null-distribution table thins out enough that asking for a p-value
    is misleading; report the effect size and let the reader judge.

    Validity: this is the small-sample exact (or here, normal-
    approximation-with-continuity-correction) test. For n < 25 a
    proper exact test is preferable but requires a permutation
    enumeration we skip; for the J=3..10 reps the bench typically
    runs the approximation is the best you can do without scipy.
    """
    nz = [d for d in diffs if d != 0.0]
    n = len(nz)
    if n < 5:
        return (None, None)
    abs_d = sorted(((abs(d), 1 if d > 0 else -1) for d in nz),
                   key=lambda x: x[0])
    # Average ranks across ties.
    ranks: list[float] = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and abs_d[j + 1][0] == abs_d[i][0]:
            j += 1
        avg_rank = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = avg_rank
        i = j + 1
    w_plus = sum(r for r, (_, s) in zip(ranks, abs_d) if s > 0)
    w_minus = sum(r for r, (_, s) in zip(ranks, abs_d) if s < 0)
    w = min(w_plus, w_minus)
    # Normal approximation with continuity correction.
    mean = n * (n + 1) / 4
    var = n * (n + 1) * (2 * n + 1) / 24
    if var == 0:
        return (w, None)
    z = (w - mean - 0.5) / math.sqrt(var) if w < mean else (w - mean + 0.5) / math.sqrt(var)
    p_two = 2 * (1 - _normal_cdf(abs(z)))
    return (w, p_two)


def _normal_cdf(x: float) -> float:
    """Standard-normal CDF — pure-python (no scipy)."""
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


def paired_comparison(rows: list[RepResult],
                      treatment: str, control: str,
                      metric: str = "best_fitness") -> dict:
    """Pair (treatment, rep_n) with (control, rep_n) and compare metric.

    Returns {n_pairs, mean_diff, median_diff, w, p_two_sided, treatment_wins}.
    Only reps that completed (status='done', metric not None) on BOTH
    sides count as a pair; the report should disclose how many reps
    were dropped.
    """
    by = {}
    for r in rows:
        if r.status != "done":
            continue
        v = getattr(r, metric, None)
        if v is None:
            continue
        by.setdefault((r.model, r.rep), v)
    pairs: list[tuple[float, float]] = []
    for rep in {k[1] for k in by if k[0] == treatment}:
        if (treatment, rep) in by and (control, rep) in by:
            pairs.append((by[(treatment, rep)], by[(control, rep)]))
    if not pairs:
        return {"n_pairs": 0}
    diffs = [t - c for t, c in pairs]
    w, p = wilcoxon_signed_rank(diffs)
    return {
        "n_pairs": len(pairs),
        "mean_diff": statistics.fmean(diffs),
        "median_diff": statistics.median(diffs),
        "w": w,
        "p_two_sided": p,
        "treatment_wins": sum(1 for d in diffs if d > 0),
        "ties": sum(1 for d in diffs if d == 0),
    }


def render_comparison_section(rows: list[RepResult]) -> str:
    """Render a 'vs static control' comparison table if a static-control
    set of reps is present in results. Each model is paired with the
    static control on shared rep numbers and tested for a fitness
    difference via the paired Wilcoxon signed-rank test.
    """
    models = sorted({r.model for r in rows})
    # Find a control. Convention: model name starts with "static" OR
    # equals "static". Pick the first match.
    control = next((m for m in models if m == "static" or m.startswith("static-")), None)
    if not control:
        return ""
    lines = [
        "",
        "## Paired vs static control",
        "",
        f"Each model paired with `{control}` on shared rep numbers; "
        "metric is `best_fitness`. p-values are two-sided Wilcoxon "
        "signed-rank with normal approximation. n<5 reports `—` for p "
        "(the null distribution is too sparse for a meaningful p-value).",
        "",
        "| Model | n_pairs | wins | mean Δ | median Δ | W | p (two-sided) |",
        "|---|---|---|---|---|---|---|",
    ]
    for m in models:
        if m == control:
            continue
        cmp = paired_comparison(rows, treatment=m, control=control)
        if cmp.get("n_pairs", 0) == 0:
            continue
        n = cmp["n_pairs"]
        w = cmp.get("w")
        p = cmp.get("p_two_sided")
        lines.append(
            f"| `{m}` | {n} | {cmp['treatment_wins']}/{n} | "
            f"{cmp['mean_diff']:+.2f} | {cmp['median_diff']:+.2f} | "
            f"{f'{w:.1f}' if w is not None else '—'} | "
            f"{f'{p:.3f}' if p is not None else '—'} |"
        )
    if len(lines) <= 7:  # only header rows, no data
        return ""
    return "\n".join(lines) + "\n"


def render_markdown(aggs: list[ModelAgg]) -> str:
    lines = [
        "# LLM hardware-development benchmark — leaderboard",
        "",
        "Sorted by mean final CoreMark fitness (iter/s) across reps. Each rep "
        "is one full tournament run (`make N=… K=… TARGET=bench`) starting "
        "from the bench-fixture core.",
        "",
        "**Outcome columns** are per-rep means: how many of a rep's "
        "iterations landed as `acc`epted improvements / `rej`ected "
        "regressions / `brk`oken (didn't compile, didn't pass formal, "
        "couldn't place on FPGA, ...). See *Failure modes* below for the "
        "broken-class breakdown.",
        "",
        "Best LUT4 / Fmax / IPC are the FPGA-side detail of the **best "
        "rep's best entry** (the one whose fitness equals `Best`). They "
        "surface the area-vs-frequency tradeoff each model picked. "
        "Baseline for reference: LUT4 = 9563, Fmax = 127 MHz, IPC ≈ 0.79.",
        "",
        "| Model | Reps | Fitness mean ± std | Best | LUT4 | Fmax MHz | IPC | acc | rej | brk | Iters→best | Pass-rate | $ cost | s/iter |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for a in aggs:
        reps_str = f"{a.n_reps_done}/{a.n_reps_done + a.n_reps_failed}"
        lines.append(
            f"| `{a.model}` | {reps_str} | "
            f"{fmt_fitness(a.fitness_mean, a.fitness_std)} | "
            f"{fmt_num(a.fitness_best)} | "
            f"{fmt_num(a.best_rep_lut4, '.0f')} | "
            f"{fmt_num(a.best_rep_fmax_mhz, '.1f')} | "
            f"{_fmt_ipc(a.best_rep_iterations, a.best_rep_cycles)} | "
            f"{fmt_num(a.accepted_mean, '.1f')} | "
            f"{fmt_num(a.rejected_mean, '.1f')} | "
            f"{fmt_num(a.broken_mean, '.1f')} | "
            f"{fmt_num(a.iters_to_best_mean, '.1f')} | "
            f"{fmt_pct(a.pass_rate)} | "
            f"${a.total_cost_usd:.2f} | "
            f"{fmt_num(a.mean_wall_clock_per_iter_sec, '.0f')} |"
        )
    lines.append("")
    return "\n".join(lines) + "\n"


def _fmt_ipc(iterations: Optional[int], cycles: Optional[int]) -> str:
    """Display IPC as iterations × 1e6 / cycles (the canonical CoreMark
    iter/s/MHz number readers expect)."""
    if not iterations or not cycles:
        return "—"
    return f"{(iterations * 1_000_000 / cycles):.2f}"


def render_failure_modes_section(aggs: list[ModelAgg]) -> str:
    """Aggregate broken_by_class across all of each model's reps.

    Pivots into a per-model section listing each broken-class with its
    total occurrence count. Empty for models with zero broken iterations.
    """
    lines = ["## Failure modes", ""]
    lines.append(
        "Counts each model's broken iterations grouped by the orchestrator's "
        "broken-class label. `formal_failed` = RTL compiled but didn't pass "
        "riscv-formal (the suffix is the first failing check). "
        "`implementation_compile_failed` = RTL didn't pass Verilator lint. "
        "`hypothesis_gen_failed` = agent didn't write the expected YAML at "
        "the slot's pre-allocated path. `placement_failed` = nextpnr "
        "couldn't place the design on the target FPGA. "
        "`make_failed_during_execution` = formal/run_all.sh's `*.sby` glob "
        "found zero tasks at tally time (usually an agent wiped the checks "
        "dir mid-run; the PID-suffix fix in `formal/run_all.sh` removes the "
        "race but the class is still emitted if anything else corrupts the "
        "checks dir)."
    )
    lines.append("")
    any_broken = False
    for a in aggs:
        if not a.broken_by_class_total:
            continue
        any_broken = True
        lines.append(f"### `{a.model}`")
        lines.append("")
        lines.append("| Class | Count |")
        lines.append("|---|---|")
        for cls, n in sorted(a.broken_by_class_total.items(),
                              key=lambda kv: (-kv[1], kv[0])):
            lines.append(f"| `{cls}` | {n} |")
        lines.append("")
    if not any_broken:
        lines.append("_No broken iterations across any model — perfect run._")
        lines.append("")
    return "\n".join(lines)


def render_per_rep_details(rows: list[RepResult]) -> str:
    """One row per (model, rep) — the un-aggregated view.

    For reps=1 runs the aggregated leaderboard collapses to the same
    numbers anyway; this section keeps the per-rep detail visible so a
    single bad rep in a 3-rep run doesn't average into invisibility.
    """
    lines = ["## Per-rep details", ""]
    lines.append(
        "Every `(model, rep)` row from `bench/results.jsonl`, "
        "before per-model aggregation."
    )
    lines.append("")
    lines.append(
        "| Model | Rep | Status | Iters | acc | rej | brk | Baseline → Final | Δ% | Best | LUT4 | Fmax MHz | IPC | Wall (m) |"
    )
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    rows_sorted = sorted(rows, key=lambda r: (r.model, r.rep))
    for r in rows_sorted:
        baseline = fmt_num(r.baseline_fitness)
        final    = fmt_num(r.final_fitness)
        delta    = fmt_pct(None if r.delta_pct is None else r.delta_pct / 100.0)
        best     = fmt_num(r.best_fitness)
        lut4     = fmt_num(r.best_lut4, '.0f') if r.best_lut4 is not None else "—"
        fmax     = fmt_num(r.best_fmax_mhz, '.1f')
        ipc      = _fmt_ipc(r.best_iterations, r.best_cycles)
        wall_min = (r.wall_clock_sec / 60.0) if r.wall_clock_sec else 0.0
        lines.append(
            f"| `{r.model}` | {r.rep} | {r.status} | {r.iterations} | "
            f"{r.accepted} | {r.rejected} | {r.broken} | "
            f"{baseline} → {final} | {delta} | {best} | "
            f"{lut4} | {fmax} | {ipc} | "
            f"{wall_min:.1f} |"
        )
    lines.append("")
    return "\n".join(lines)


def render_winning_hypotheses(rows: list[RepResult], results_dir: Path) -> str:
    """For each (model, rep), list every accepted-improvement entry's
    title from its preserved log.jsonl. The runner copies log.jsonl into
    bench/<model>/rep<N>/log.jsonl after the rep finalizes.

    This is the publishable narrative: what each model actually *did* to
    achieve its fitness gain. The baseline retest entry (round_id=0) is
    elided since its title is always the boring "Baseline retest for ...".
    """
    lines = ["## Winning hypotheses", ""]
    lines.append(
        "Each model's accepted-improvement entries (the hypotheses that "
        "actually moved the fitness needle), in order. Pulled from the "
        "preserved `bench/<model>/rep<N>/log.jsonl`."
    )
    lines.append("")
    rows_sorted = sorted(rows, key=lambda r: (r.model, r.rep))
    any_wins = False
    for r in rows_sorted:
        log_path = results_dir / r.model / f"rep{r.rep}" / "log.jsonl"
        if not log_path.is_file():
            continue
        entries: list[dict] = []
        for raw in log_path.read_text().splitlines():
            s = raw.strip()
            if not s:
                continue
            try:
                entries.append(json.loads(s))
            except json.JSONDecodeError:
                continue
        wins = [e for e in entries
                if e.get("outcome") in ("improvement", "accepted")
                and e.get("round_id") != 0]
        if not wins:
            continue
        any_wins = True
        lines.append(f"### `{r.model}` rep {r.rep}")
        lines.append("")
        for w in wins:
            title    = w.get("title") or w.get("id") or "<untitled>"
            fit      = w.get("fitness")
            delta    = w.get("delta_pct")
            cat      = w.get("category") or ""
            round_id = w.get("round_id")
            lut4     = w.get("lut4")
            fmax     = w.get("fmax_mhz")
            fit_str   = fmt_num(fit) if fit is not None else "?"
            delta_str = f"{delta:+.1f}%" if isinstance(delta, (int, float)) else ""
            cat_str   = f" _{cat}_" if cat else ""
            rid_str   = f" R{round_id}" if round_id is not None else ""
            hw_str    = ""
            if isinstance(lut4, (int, float)) or isinstance(fmax, (int, float)):
                lut_s = f"LUT4 {int(lut4)}" if isinstance(lut4, (int, float)) else ""
                fmax_s = f"{fmax:.1f} MHz" if isinstance(fmax, (int, float)) else ""
                hw_str = " — " + ", ".join(s for s in (lut_s, fmax_s) if s)
            lines.append(f"- **{title}** — fitness {fit_str} ({delta_str}){cat_str}{rid_str}{hw_str}")
        lines.append("")
    if not any_wins:
        lines.append("_No accepted improvements recorded across any rep._")
        lines.append("")
    return "\n".join(lines)


def render_csv(aggs: list[ModelAgg], out: Path) -> None:
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "model", "n_reps_done", "n_reps_failed",
            "fitness_mean", "fitness_std", "fitness_best",
            "best_rep_lut4", "best_rep_ff", "best_rep_fmax_mhz",
            "best_rep_iterations", "best_rep_cycles", "best_rep_ipc_coremark",
            "iters_to_best_mean", "pass_rate", "total_cost_usd",
            "mean_wall_clock_per_iter_sec",
            "total_tokens_in", "total_tokens_out",
        ])
        for a in aggs:
            w.writerow([
                a.model, a.n_reps_done, a.n_reps_failed,
                a.fitness_mean if a.fitness_mean is not None else "",
                a.fitness_std if a.fitness_std is not None else "",
                a.fitness_best if a.fitness_best is not None else "",
                a.best_rep_lut4 if a.best_rep_lut4 is not None else "",
                a.best_rep_ff if a.best_rep_ff is not None else "",
                a.best_rep_fmax_mhz if a.best_rep_fmax_mhz is not None else "",
                a.best_rep_iterations if a.best_rep_iterations is not None else "",
                a.best_rep_cycles if a.best_rep_cycles is not None else "",
                a.best_rep_ipc_coremark if a.best_rep_ipc_coremark is not None else "",
                a.iters_to_best_mean if a.iters_to_best_mean is not None else "",
                a.pass_rate if a.pass_rate is not None else "",
                a.total_cost_usd,
                a.mean_wall_clock_per_iter_sec if a.mean_wall_clock_per_iter_sec is not None else "",
                a.total_tokens_in, a.total_tokens_out,
            ])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR,
                    help="output directory (default: bench/)")
    args = ap.parse_args()

    rows = load_results(args.results)
    if not rows:
        print(f"no rows in {args.results} — run the benchmark first")
        return 1
    aggs = aggregate(rows)

    args.out.mkdir(parents=True, exist_ok=True)
    md_path = args.out / "LEADERBOARD.md"
    csv_path = args.out / "leaderboard.csv"
    md_parts = [
        render_markdown(aggs),
        render_comparison_section(rows),
        render_failure_modes_section(aggs),
        render_per_rep_details(rows),
        render_winning_hypotheses(rows, args.out),
        "Generated by `python -m tools.bench.report`. "
        "Source data: `bench/results.jsonl` + per-rep `bench/<model>/rep<N>/log.jsonl`.\n",
    ]
    md_path.write_text("\n".join(md_parts))
    render_csv(aggs, csv_path)

    print(f"wrote {md_path}")
    print(f"wrote {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
