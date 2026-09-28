#!/usr/bin/env python3
"""Analysis for EXP-2026-09-28-v2-noise-server (rules in its prereg.yaml).

sigma_between: per design, SD over variants of ln(mean Fmax over seeds 1-2);
sigma_seed: per design, pooled SD of ln(Fmax) between seeds within a variant;
sigma_P: SD of ln(median of P draws), each draw a variant chosen with
replacement and one of its seeds at random (Monte Carlo). All pooled by RMS
over designs. Margin = 2.33 * sigma_9.

Usage: analyze_noise_server.py <runs.jsonl> [--samples 20000]
"""
import argparse
import json
import math
import random
import statistics as st
from collections import defaultdict


def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / len(xs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs")
    ap.add_argument("--samples", type=int, default=20000)
    a = ap.parse_args()
    by = defaultdict(lambda: defaultdict(dict))   # design -> k -> seed -> fmax
    for line in open(a.runs):
        r = json.loads(line)
        if "error" in r:
            continue
        by[r["design"]][r["k"]][r["seed"]] = r["fmax_mhz"]
    rng = random.Random(20260928)

    print("| design | variants | failed variants | median MHz | min | max | sigma_between | sigma_seed | sigma_9 | sigma_15 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    pooled = defaultdict(list)
    for d, ks in by.items():
        variants, failed = [], 0
        for k, seeds in ks.items():
            ok = [seeds[s] for s in (1, 2) if seeds.get(s)]
            if not ok:
                failed += 1
                continue
            variants.append(ok)
        if failed > len(ks) / 3 or len(variants) < 3:
            print(f"| {d} | {len(ks)} | {failed} | excluded | | | | | | |")
            continue
        means = [st.mean(v) for v in variants]
        sb = st.stdev([math.log(m) for m in means])
        within = [st.stdev([math.log(x) for x in v]) for v in variants if len(v) == 2]
        ss = rms(within)
        sp = {}
        for P in (9, 15):
            draws = [math.log(st.median(rng.choice(rng.choice(variants)) for _ in range(P)))
                     for _ in range(a.samples)]
            sp[P] = st.stdev(draws)
        for key, v in (("between", sb), ("seed", ss), (9, sp[9]), (15, sp[15])):
            pooled[key].append(v)
        print(f"| {d} | {len(ks)} | {failed} | {st.median(means):.2f} | {min(means):.2f} | "
              f"{max(means):.2f} | {sb:.4f} | {ss:.4f} | {sp[9]:.4f} | {sp[15]:.4f} |")
    out = {k if isinstance(k, str) else f"P{k}": rms(v) for k, v in pooled.items()}
    out["designs"] = len(pooled["between"])
    out["margin_ln"] = 2.33 * out["P9"]
    out["margin_pct"] = 100 * (math.exp(out["margin_ln"]) - 1)
    print("\n" + json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
