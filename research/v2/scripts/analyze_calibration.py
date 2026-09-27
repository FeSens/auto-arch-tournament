#!/usr/bin/env python3
"""Analysis for EXP-2026-09-27-v2-placement-noise.

Part 1 applies the pre-registered rules exactly (prereg.yaml): per design,
the SD of ln(median Fmax) over its 9 variants, for median-of-3 and
median-of-5 seeds; pooled by RMS over designs; seed-count rule; margin.

Part 2 (amendment, decided after seeing Part 1, labelled as such) sizes a
score that is a median over P (perturbation, seed) pairs, one seed per
distinct perturbation: its SD is estimated by Monte Carlo from the measured
variants, drawing perturbations with replacement (a fresh design meets the
perturbation set as new, independent draws) and one seed per drawn variant.

Usage: analyze_calibration.py <runs.jsonl> [--draws 20000]
"""
import argparse
import json
import math
import random
import statistics as st
from collections import defaultdict
from pathlib import Path


def load(path: Path):
    by = defaultdict(lambda: defaultdict(dict))   # design -> k -> seed -> fmax
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if "error" in r:
            continue
        by[r["design"]][r["k"]][r["seed"]] = r["fmax_mhz"]
    return by


def med(vals):
    ok = [v for v in vals if v is not None]
    if len(vals) - len(ok) >= 2:     # stop rule: >=2 failed seeds -> excluded
        return None
    return st.median(ok)


def rms(xs):
    return math.sqrt(sum(x * x for x in xs) / len(xs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", type=Path)
    ap.add_argument("--draws", type=int, default=20000)
    a = ap.parse_args()
    by = load(a.runs)
    rng = random.Random(20260927)

    print("## Part 1: pre-registered analysis\n")
    print("| design | variants | k=0 med3 | min med3 | max med3 | sd ln med3 | sd ln med5 | within-variant seed sd (ln) |")
    print("|---|---|---|---|---|---|---|---|")
    s3, s5, sw_all, sb_all = [], [], [], []
    complete = []
    for d, ks in by.items():
        m3 = {k: med([sd.get(s) for s in (1, 2, 3)]) for k, sd in ks.items()}
        m5 = {k: med([sd.get(s) for s in (1, 2, 3, 4, 5)]) for k, sd in ks.items()}
        v3 = [math.log(x) for x in m3.values() if x]
        v5 = [math.log(x) for x in m5.values() if x]
        # Seed-to-seed SD inside a variant (seeds 1..5), pooled over variants.
        within = [st.stdev([math.log(sd[s]) for s in (1, 2, 3, 4, 5) if sd.get(s)])
                  for sd in ks.values() if sum(1 for s in (1, 2, 3, 4, 5) if sd.get(s)) >= 3]
        sw = rms(within) if within else float("nan")
        if len(v3) < 3 or len(v5) < 3:
            print(f"| {d} | {len(ks)} | (incomplete) | | | | | |")
            continue
        s3.append(st.stdev(v3)); s5.append(st.stdev(v5))
        sw_all.append(sw)
        if len(ks) == 9:
            complete.append(d)
        print(f"| {d} | {len(ks)} | {m3.get(0) or 'n/a'} | {min(filter(None, m3.values())):.2f} | "
              f"{max(filter(None, m3.values())):.2f} | {st.stdev(v3):.4f} | {st.stdev(v5):.4f} | {sw:.4f} |")
    sig3, sig5 = rms(s3), rms(s5)
    seeds = 5 if sig5 <= 0.8 * sig3 else 3
    sig = sig5 if seeds == 5 else sig3
    print(f"\npooled sigma: median-of-3 {sig3:.4f}, median-of-5 {sig5:.4f} "
          f"(n={len(s3)} designs; complete: {len(complete)}/{len(by)})")
    print(f"seed rule: sigma5 <= 0.8*sigma3 ? {sig5:.4f} <= {0.8 * sig3:.4f} -> {seeds} seeds")
    print(f"margin: 2.33*sigma = {2.33 * sig:.4f} in ln = {100 * (math.exp(2.33 * sig) - 1):.1f}%")
    print(f"pooled within-variant seed sd (ln): {rms(sw_all):.4f}")

    print("\n## Part 2 (amendment): median over P (perturbation, seed) pairs\n")
    print("| P | pooled sd ln(score) | margin 2.33 sd (ln) | margin (%) |")
    print("|---|---|---|---|")
    out = {}
    for P in (1, 3, 5, 7, 9, 11, 15):
        sds = []
        for d, ks in by.items():
            variants = [[v for v in sd.values() if v] for sd in ks.values()]
            variants = [v for v in variants if v]
            if len(variants) < 3:
                continue
            draws = []
            for _ in range(a.draws // 10):
                draws.append(math.log(st.median(rng.choice(rng.choice(variants)) for _ in range(P))))
            sds.append(st.stdev(draws))
        s = rms(sds)
        out[P] = s
        print(f"| {P} | {s:.4f} | {2.33 * s:.4f} | {100 * (math.exp(2.33 * s) - 1):.1f} |")
    print("\n" + json.dumps({"sigma3": sig3, "sigma5": sig5, "seeds": seeds,
                             "margin_ln": 2.33 * sig, "pairs_sd": out}))


if __name__ == "__main__":
    main()
