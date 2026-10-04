#!/usr/bin/env python3
"""Analysis 6: does CoreMark progress transfer to the held-out kernels?

Per run (the final champion, which is what the held-out score measures):
  CoreMark score   final_fitness from the results row (the champion's
                   fitness; best_fitness can be a rejected candidate that
                   scored higher by less than the 4.6% margin)
  CoreMark IPC     iterations / cycles of the champion's log.jsonl row (the
                   last accepted candidate), reported per million cycles
  held-out score   holdout_geomean_iter_s = holdout Fmax x geomean over the
                   five kernels (dhrystone, aha-mont64, crc32, matmult-int,
                   edn) of reps / cycles
  held-out IPC     geomean of reps / cycles (= held-out score / Fmax), per
                   million cycles
  ratio            held-out score / CoreMark score. Fmax cancels when the
                   held-out Fmax equals the champion's loop Fmax, which holds
                   for every run checked below, so the ratio is the held-out
                   IPC / CoreMark IPC ratio.
"Transfer index" = a run's ratio divided by the median ratio of the 36 runs
(1.00 = typical; below 1 = the held-out kernels gained less than CoreMark).
Per-kernel index: the run's kernel IPC / CoreMark IPC, divided by the median
of that quantity over the 36 runs, which shows which kernel drags a run down.
Context: the same ratio for the ten open-source reference cores in
research/v2/reference_cores/results_sim (simulated with the harness's ELFs,
stall model and scoring).
"""
from __future__ import annotations

import glob
import json
import math
import statistics

import common as c

KERNELS = ["dhrystone", "aha-mont64", "crc32", "matmult-int", "edn"]


def champion_row(m, r):
    acc = [d for d in c.load_log(m, r) if d["outcome"] == "improvement"]
    return max(acc, key=lambda d: (d["round_id"], d["slot"]))


def main():
    rows = c.load_scored_rows()
    runs = []
    problems = []
    for m in c.MODELS:
        for r in c.REPS:
            row = rows[(m, r)]
            ch = champion_row(m, r)
            if abs(ch["fitness"] - row["final_fitness"]) > 0.01:
                problems.append(f"{c.NAME[m]} rep{r}: champion fitness {ch['fitness']} vs final_fitness {row['final_fitness']}")
            k = row["holdout_kernels"]
            fmax_h = row["holdout_fmax_mhz"]
            ipc = {kk: k[kk]["reps"] / k[kk]["cycles"] for kk in KERNELS}
            g_ipc = c.geomean(ipc.values())
            recon = fmax_h * 1e6 * g_ipc
            if abs(recon - row["holdout_geomean_iter_s"]) / row["holdout_geomean_iter_s"] > 1e-6:
                problems.append(f"{c.NAME[m]} rep{r}: held-out recomputed {recon:.2f} vs {row['holdout_geomean_iter_s']:.2f}")
            if abs(fmax_h - ch["fmax_mhz"]) > 1e-6:
                problems.append(f"{c.NAME[m]} rep{r}: held-out Fmax {fmax_h} vs champion Fmax {ch['fmax_mhz']}")
            cm_ipc = ch["iterations"] / ch["cycles"]
            runs.append({
                "system": c.NAME[m], "model": m, "rep": r,
                "coremark": row["final_fitness"], "coremark_best_any_candidate": row["best_fitness"],
                "holdout": row["holdout_geomean_iter_s"], "fmax_champion": ch["fmax_mhz"], "fmax_holdout": fmax_h,
                "coremark_ipc_per_Mcycle": cm_ipc * 1e6, "holdout_ipc_per_Mcycle": g_ipc * 1e6,
                "kernel_ipc_per_Mcycle": {kk: v * 1e6 for kk, v in ipc.items()},
                "ratio": row["holdout_geomean_iter_s"] / row["final_fitness"],
                "lut4": ch.get("lut4"), "champion_id": ch["id"],
            })
    med_ratio = statistics.median(x["ratio"] for x in runs)
    kmed = {kk: statistics.median(x["kernel_ipc_per_Mcycle"][kk] / x["coremark_ipc_per_Mcycle"] for x in runs)
            for kk in KERNELS}
    for x in runs:
        x["transfer_index"] = x["ratio"] / med_ratio
        x["kernel_index"] = {kk: (x["kernel_ipc_per_Mcycle"][kk] / x["coremark_ipc_per_Mcycle"]) / kmed[kk]
                             for kk in KERNELS}

    xs = [x["coremark"] for x in runs]
    ys = [x["holdout"] for x in runs]
    groups = [([x["coremark"] for x in runs if x["model"] == m], [x["holdout"] for x in runs if x["model"] == m])
              for m in c.MODELS]
    ipc_groups = [([x["coremark_ipc_per_Mcycle"] for x in runs if x["model"] == m],
                   [x["holdout_ipc_per_Mcycle"] for x in runs if x["model"] == m]) for m in c.MODELS]
    corr = {
        "coremark_vs_holdout": {
            "pooled_36": c.spearman(xs, ys),
            "pearson_log_pooled_36": c.pearson([math.log(v) for v in xs], [math.log(v) for v in ys]),
            "stratified_within_system": c.stratified_spearman(groups),
            "per_system": {c.NAME[m]: c.spearman(*g) for m, g in zip(c.MODELS, groups)}},
        "coremark_ipc_vs_holdout_ipc": {
            "pooled_36": c.spearman([x["coremark_ipc_per_Mcycle"] for x in runs], [x["holdout_ipc_per_Mcycle"] for x in runs]),
            "stratified_within_system": c.stratified_spearman(ipc_groups),
            "per_system": {c.NAME[m]: c.spearman(*g) for m, g in zip(c.MODELS, ipc_groups)}},
        "fmax_vs_holdout": c.spearman([x["fmax_holdout"] for x in runs], ys),
        "coremark_ipc_vs_holdout": c.spearman([x["coremark_ipc_per_Mcycle"] for x in runs], ys),
    }

    refs = []
    for f in sorted(glob.glob(str(c.REPO / "research" / "v2" / "reference_cores" / "results_sim" / "*.json"))):
        d = json.loads(open(f).read())
        cm = d.get("coremark", {}).get("score")
        ho = d.get("holdout_geomean_iter_s")
        if cm and ho:
            refs.append({"core": d["core"], "coremark": cm, "holdout": ho, "ratio": ho / cm,
                         "transfer_index": ho / cm / med_ratio})

    per_sys = {}
    for m in c.MODELS:
        rs = [x for x in runs if x["model"] == m]
        per_sys[c.NAME[m]] = {
            "coremark_median": statistics.median(x["coremark"] for x in rs),
            "holdout_median": statistics.median(x["holdout"] for x in rs),
            "ratio_median": statistics.median(x["ratio"] for x in rs),
            "ratio_min": min(x["ratio"] for x in rs), "ratio_max": max(x["ratio"] for x in rs),
            "coremark_ipc_median": statistics.median(x["coremark_ipc_per_Mcycle"] for x in rs),
            "holdout_ipc_median": statistics.median(x["holdout_ipc_per_Mcycle"] for x in rs),
            "fmax_median": statistics.median(x["fmax_holdout"] for x in rs),
            "kernel_index_median": {kk: statistics.median(x["kernel_index"][kk] for x in rs) for kk in KERNELS},
        }
    worst = sorted(runs, key=lambda x: x["transfer_index"])[:6]
    best = sorted(runs, key=lambda x: -x["transfer_index"])[:3]

    data = {"runs": runs, "per_system": per_sys, "median_ratio_36": med_ratio, "spearman": corr,
            "reference_cores": refs, "consistency_problems": problems, "notes": __doc__}

    rp = c.fmt_rho
    L = ["# Analysis 6: transfer from CoreMark to the held-out kernels", "",
         f"Median held-out / CoreMark ratio over the 36 runs: {med_ratio:.2f}. "
         f"Spearman between CoreMark and held-out score: pooled {rp(corr['coremark_vs_holdout']['pooled_36'])}, "
         f"within-system ranks {rp(corr['coremark_vs_holdout']['stratified_within_system'])}. "
         f"CoreMark IPC vs held-out IPC: pooled {rp(corr['coremark_ipc_vs_holdout_ipc']['pooled_36'])}, "
         f"within-system ranks {rp(corr['coremark_ipc_vs_holdout_ipc']['stratified_within_system'])}.", ""]
    hdr = ["system", "CoreMark iter/s", "held-out iter/s", "ratio median (min to max)", "Fmax MHz",
           "CoreMark iter/Mcycle", "held-out iter/Mcycle", "rho CoreMark vs held-out (n=6)",
           "rho CoreMark IPC vs held-out IPC (n=6)"]
    body = []
    for m in c.MODELS:
        n = c.NAME[m]
        d = per_sys[n]
        body.append([n, f"{d['coremark_median']:.1f}", f"{d['holdout_median']:.0f}",
                     f"{d['ratio_median']:.2f} ({d['ratio_min']:.2f} to {d['ratio_max']:.2f})",
                     f"{d['fmax_median']:.1f}", f"{d['coremark_ipc_median']:.3f}", f"{d['holdout_ipc_median']:.1f}",
                     rp(corr["coremark_vs_holdout"]["per_system"][n]),
                     rp(corr["coremark_ipc_vs_holdout_ipc"]["per_system"][n])])
    L += ["Per system, medians over 6 runs:", "", c.md_table(hdr, body), ""]
    L += ["Per-kernel transfer index, system median (kernel IPC / CoreMark IPC, relative to the 36-run median; "
          "below 1 = this kernel gained less than CoreMark):", ""]
    body = [[n] + [f"{d['kernel_index_median'][kk]:.2f}" for kk in KERNELS] for n, d in per_sys.items()]
    L += [c.md_table(["system"] + KERNELS, body), ""]
    L += ["Runs that transfer worst (lowest transfer index) and best:", ""]
    hdr = ["system", "rep", "CoreMark", "held-out", "ratio", "transfer index", "weakest kernel (index)"]
    body = []
    for x in worst + best:
        wk = min(KERNELS, key=lambda kk: x["kernel_index"][kk])
        body.append([x["system"], x["rep"], f"{x['coremark']:.1f}", f"{x['holdout']:.0f}", f"{x['ratio']:.2f}",
                     f"{x['transfer_index']:.2f}", f"{wk} ({x['kernel_index'][wk]:.2f})"])
    L += [c.md_table(hdr, body), ""]
    L += ["Open-source reference cores (same ELFs, stall model and scoring, simulated):", ""]
    body = [[x["core"], f"{x['coremark']:.1f}", f"{x['holdout']:.0f}", f"{x['ratio']:.2f}", f"{x['transfer_index']:.2f}"]
            for x in sorted(refs, key=lambda x: -x["holdout"])]
    L += [c.md_table(["core", "CoreMark", "held-out", "ratio", "transfer index"], body), ""]
    L += ["All runs:", ""]
    hdr = ["system", "rep", "CoreMark", "held-out", "ratio", "transfer index", "Fmax", "CoreMark iter/Mcycle",
           "held-out iter/Mcycle"] + [f"{kk} index" for kk in KERNELS]
    body = [[x["system"], x["rep"], f"{x['coremark']:.1f}", f"{x['holdout']:.0f}", f"{x['ratio']:.2f}",
             f"{x['transfer_index']:.2f}", f"{x['fmax_holdout']:.1f}", f"{x['coremark_ipc_per_Mcycle']:.3f}",
             f"{x['holdout_ipc_per_Mcycle']:.1f}"] + [f"{x['kernel_index'][kk]:.2f}" for kk in KERNELS] for x in runs]
    L += [c.md_table(hdr, body), ""]
    if problems:
        L += ["Consistency problems:", ""] + [f"- {p}" for p in problems]
    else:
        L += ["Checks: every champion row's fitness equals the results row's final_fitness; every held-out score "
              "equals Fmax x geomean(reps/cycles) recomputed from its kernels; held-out Fmax equals the champion's "
              "loop Fmax in all 36 runs."]
    c.write_outputs("a6_transfer", data, "\n".join(L))


if __name__ == "__main__":
    main()
