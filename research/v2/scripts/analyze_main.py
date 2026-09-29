#!/usr/bin/env python3
"""Pre-registered analysis of the V2 main campaign (EXP-2026-09-28-v2-main).

prereg.yaml: primary metric ln(held-out score) of each run's final champion
(`holdout_geomean_iter_s`, Gowin Fmax times the geometric mean of held-out
iterations per cycle); primary test Opus vs Sol, Welch two-sided at 0.05,
ratio of geometric means with its 95% CI, plus a 10,000-sample percentile
bootstrap CI. Amendment 01: Luna vs Sol and Luna vs Opus, same test,
Holm-adjusted across those two at family alpha 0.05. Verdict: a system ranks
higher only when the CI of the ratio excludes 1 and p < 0.05; otherwise "not
distinguishable at n=6".

Incident policy: the scored run of a (system, rep) is the first complete one
(status done with a held-out score) in order of completion; every attempt is
listed. Runs are never dropped for being low.

Amendment 11: GPT-6.1 Sol replaces GPT-6 Sol as "Sol" in every test; GPT-6
Sol's one run (rep1) is listed as an unscored pilot.

    research/v2/scripts/analyze_main.py bench/v2/results.jsonl \
        bench/v2/results-opus-luna.jsonl bench/v2/results-sol61.jsonl \
        --rescored research/runs/EXP-2026-09-28-v2-main/incident_08/holdout_rescored.jsonl [--json out.json]

Standard library only (the run host has no scipy): Student t via the
regularized incomplete beta function.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import statistics
from pathlib import Path

PRIMARY = ("claude-opus-5_5_xhigh-v2", "gpt-6_1-sol_xhigh-v2")
SECONDARY = [("gpt-6-luna_xhigh-v2", "gpt-6_1-sol_xhigh-v2"),
             ("gpt-6-luna_xhigh-v2", "claude-opus-5_5_xhigh-v2")]
SHORT = {"claude-opus-5_5_xhigh-v2": "Opus", "gpt-6_1-sol_xhigh-v2": "Sol 6.1",
         "gpt-6-luna_xhigh-v2": "Luna"}
PILOTS = {"gpt-6-sol_xhigh-v2": "GPT-6 Sol (pilot)"}
ALPHA = 0.05
BOOT = 10_000
SEED = 20260928


# ---- Student t (no scipy) -------------------------------------------------

def _betacf(a: float, b: float, x: float) -> float:
    """Continued fraction for the incomplete beta (Numerical Recipes 6.4)."""
    tiny, eps = 1e-300, 3e-16
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 400):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def betainc(a: float, b: float, x: float) -> float:
    """Regularized incomplete beta I_x(a, b)."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbt = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
           + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1.0) / (a + b + 2.0):
        return math.exp(lbt) * _betacf(a, b, x) / a
    return 1.0 - math.exp(lbt) * _betacf(b, a, 1.0 - x) / b


def t_sf2(t: float, df: float) -> float:
    """Two-sided p-value P(|T| >= |t|) for Student t with df degrees of freedom."""
    return betainc(df / 2.0, 0.5, df / (df + t * t))


def t_ppf(q: float, df: float) -> float:
    """Quantile of Student t (q in (0.5, 1)), by bisection on t_sf2."""
    target = 2.0 * (1.0 - q)
    lo, hi = 0.0, 1e3
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if t_sf2(mid, df) > target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


# ---- the pre-registered test ----------------------------------------------

def welch(a: list[float], b: list[float]) -> dict:
    """Welch test of mean(a) - mean(b) on ln scores; ratio = exp(difference)."""
    na, nb = len(a), len(b)
    ma, mb = statistics.fmean(a), statistics.fmean(b)
    va, vb = statistics.variance(a), statistics.variance(b)
    se2 = va / na + vb / nb
    se = math.sqrt(se2)
    df = se2 ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    diff = ma - mb
    t = diff / se
    half = t_ppf(1 - ALPHA / 2, df) * se
    return {"diff_ln": diff, "t": t, "df": df, "p": t_sf2(t, df),
            "ratio": math.exp(diff),
            "ci95": [math.exp(diff - half), math.exp(diff + half)]}


def bootstrap_ratio(a: list[float], b: list[float], n: int = BOOT, seed: int = SEED) -> list[float]:
    """Percentile 95% CI of exp(mean(a) - mean(b)), resampling each group."""
    rng = random.Random(seed)
    diffs = sorted(
        statistics.fmean(rng.choices(a, k=len(a))) - statistics.fmean(rng.choices(b, k=len(b)))
        for _ in range(n))
    return [math.exp(diffs[int(0.025 * n)]), math.exp(diffs[int(0.975 * n) - 1])]


def holm(ps: list[float]) -> list[float]:
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    adj, running = [0.0] * len(ps), 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (len(ps) - rank) * ps[i]))
        adj[i] = running
    return adj


def verdict(res: dict, p: float, a: str, b: str) -> str:
    lo, hi = res["ci95"]
    if p < ALPHA and (lo > 1 or hi < 1):
        hi_sys, lo_sys = (a, b) if res["ratio"] > 1 else (b, a)
        return f"{SHORT[hi_sys]} ranks higher than {SHORT[lo_sys]} on this contract"
    return "not distinguishable at this n; no ranking claimed"


# ---- runs ------------------------------------------------------------------

HOLDOUT_FIELDS = ("holdout_geomean_iter_s", "holdout_kernels", "holdout_fmax_mhz",
                  "loop_fmax_mhz", "holdout_fmax_pairs", "holdout_error")


def load(results: Path | list[Path], rescored: list[Path] = ()) -> tuple[dict, list[dict]]:
    """Result rows, with held-out scores recomputed after the run (incident 08:
    the 2.8.0 runner's bundle, and so its held-out scoring, failed under a
    relative --results-dir) merged into the attempt they belong to, matched
    by model, rep and start time. A rescored value never creates an attempt."""
    rows = [json.loads(l) for f in ([results] if isinstance(results, Path) else results)
            for l in f.read_text().splitlines() if l.strip()]
    for path in rescored:
        for l in path.read_text().splitlines():
            if not l.strip():
                continue
            fix = json.loads(l)
            hits = [r for r in rows if (r.get("model"), r.get("rep"), r.get("started_at"))
                    == (fix["model"], fix["rep"], fix["attempt_started_at"])]
            if len(hits) != 1:
                raise SystemExit(f"rescored row matches {len(hits)} attempts: {fix['model']} rep {fix['rep']}")
            if hits[0].get("holdout_geomean_iter_s") is not None:
                raise SystemExit(f"{fix['model']} rep {fix['rep']} already has a held-out score")
            hits[0].update({k: fix.get(k) for k in HOLDOUT_FIELDS})
            hits[0]["holdout_source"] = f"rescored ({path.name})"
    rows.sort(key=lambda r: r.get("ended_at") or "")
    scored: dict[tuple[str, int], dict] = {}
    for r in rows:
        key = (r.get("model"), r.get("rep"))
        if key in scored:
            continue
        if r.get("status") == "done" and r.get("holdout_geomean_iter_s"):
            scored[key] = r
    return scored, rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("results", type=Path, nargs="+",
                    help="results files (amendment 11: the 2.8.0 file plus each 2.8.1 runner's)")
    ap.add_argument("--json", type=Path, help="also write the numbers here")
    ap.add_argument("--rescored", type=Path, action="append", default=[],
                    help="held-out scores recomputed after a run (incident 08 holdout_rescored.jsonl)")
    args = ap.parse_args()
    scored, rows = load(args.results, args.rescored)

    print("## Attempts (order of completion)\n")
    print("| system | rep | status | held-out iter/s | held-out source | scored |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        key = (r.get("model"), r.get("rep"))
        s = r.get("holdout_geomean_iter_s")
        name = SHORT.get(r.get("model")) or PILOTS.get(r.get("model"), r.get("model"))
        used = "pilot" if r.get("model") in PILOTS else ("yes" if scored.get(key) is r else "")
        print(f"| {name} | {r.get('rep')} | {r.get('status')} | "
              f"{'' if s is None else f'{s:.1f}'} | {r.get('holdout_source', 'runner' if s is not None else '')} | "
              f"{used} |")

    ln = {m: [math.log(r["holdout_geomean_iter_s"]) for (mm, _), r in sorted(scored.items()) if mm == m]
          for m in SHORT}
    print("\n## Scored runs per system\n")
    print("| system | n | geomean held-out iter/s | SD of ln (run-to-run) |")
    print("|---|---|---|---|")
    for m, xs in ln.items():
        sd = statistics.stdev(xs) if len(xs) > 1 else float("nan")
        gm = math.exp(statistics.fmean(xs)) if xs else float("nan")
        print(f"| {SHORT[m]} | {len(xs)} | {gm:.1f} | {sd:.3f} |")

    out: dict = {"n": {SHORT[m]: len(xs) for m, xs in ln.items()}}
    if all(len(ln[m]) >= 2 for m in PRIMARY):
        a, b = PRIMARY
        res = welch(ln[a], ln[b])
        res["boot95"] = bootstrap_ratio(ln[a], ln[b])
        res["verdict"] = verdict(res, res["p"], a, b)
        out["primary"] = res
        print(f"\n## Primary: {SHORT[a]} vs {SHORT[b]} (Welch on ln held-out score)\n")
        print(f"ratio of geometric means {res['ratio']:.3f}, 95% CI [{res['ci95'][0]:.3f}, {res['ci95'][1]:.3f}], "
              f"bootstrap 95% CI [{res['boot95'][0]:.3f}, {res['boot95'][1]:.3f}]; "
              f"t = {res['t']:.2f}, df = {res['df']:.1f}, p = {res['p']:.4f}")
        print(f"Verdict: {res['verdict']}")
    else:
        print("\nPrimary test needs at least 2 scored runs per system.")

    pairs = [(a, b) for a, b in SECONDARY if len(ln[a]) >= 2 and len(ln[b]) >= 2]
    if len(pairs) == len(SECONDARY):
        res = [welch(ln[a], ln[b]) for a, b in pairs]
        for r, p_adj, (a, b) in zip(res, holm([r["p"] for r in res]), pairs):
            r["p_holm"] = p_adj
            r["boot95"] = bootstrap_ratio(ln[a], ln[b])
            r["verdict"] = verdict(r, p_adj, a, b)
        out["secondary"] = {f"{SHORT[a]} vs {SHORT[b]}": r for r, (a, b) in zip(res, pairs)}
        print("\n## Secondary (amendment 01, Holm across the two)\n")
        for name, r in out["secondary"].items():
            print(f"{name}: ratio {r['ratio']:.3f}, 95% CI [{r['ci95'][0]:.3f}, {r['ci95'][1]:.3f}], "
                  f"bootstrap [{r['boot95'][0]:.3f}, {r['boot95'][1]:.3f}]; p = {r['p']:.4f}, "
                  f"Holm p = {r['p_holm']:.4f}. {r['verdict']}")
    if args.json:
        args.json.write_text(json.dumps(out, indent=2) + "\n")


if __name__ == "__main__":
    main()
