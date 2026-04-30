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
    iterations: int
    accepted: int
    rejected: int
    broken: int
    delta_pct: Optional[float]
    wall_clock_sec: int
    total_cost_usd: float
    total_tokens_in: int
    total_tokens_out: int


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
            iterations=int(row.get("iterations") or 0),
            accepted=int(row.get("accepted") or 0),
            rejected=int(row.get("rejected") or 0),
            broken=int(row.get("broken") or 0),
            delta_pct=row.get("delta_pct"),
            wall_clock_sec=int(row.get("wall_clock_sec") or 0),
            total_cost_usd=float(row.get("total_cost_usd") or 0.0),
            total_tokens_in=int(row.get("total_tokens_in") or 0),
            total_tokens_out=int(row.get("total_tokens_out") or 0),
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
        ))

    out.sort(key=lambda a: (-(a.fitness_mean or -math.inf), a.model))
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


def render_markdown(aggs: list[ModelAgg]) -> str:
    lines = [
        "# LLM hardware-development benchmark — leaderboard",
        "",
        "Sorted by mean final CoreMark fitness (iter/s) across reps.",
        "Each rep is one full `make N=10 K=3 TARGET=bench` tournament run "
        "starting from the frozen `bench-fixture-v1` core.",
        "",
        "| Model | Reps | Fitness mean ± std | Best | Iters→best | Pass-rate | $ cost | s/iter |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for a in aggs:
        reps_str = f"{a.n_reps_done}/{a.n_reps_done + a.n_reps_failed}"
        lines.append(
            f"| `{a.model}` | {reps_str} | "
            f"{fmt_fitness(a.fitness_mean, a.fitness_std)} | "
            f"{fmt_num(a.fitness_best)} | "
            f"{fmt_num(a.iters_to_best_mean, '.1f')} | "
            f"{fmt_pct(a.pass_rate)} | "
            f"${a.total_cost_usd:.2f} | "
            f"{fmt_num(a.mean_wall_clock_per_iter_sec, '.0f')} |"
        )
    lines.append("")
    lines.append("Generated by `python -m tools.bench.report`. "
                 "Source data: `bench/results.jsonl`.")
    return "\n".join(lines) + "\n"


def render_csv(aggs: list[ModelAgg], out: Path) -> None:
    with out.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "model", "n_reps_done", "n_reps_failed",
            "fitness_mean", "fitness_std", "fitness_best",
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
    md_path.write_text(render_markdown(aggs))
    render_csv(aggs, csv_path)

    print(f"wrote {md_path}")
    print(f"wrote {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
