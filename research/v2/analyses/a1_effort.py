#!/usr/bin/env python3
"""Analysis 1: effort (tokens, cost, wall time) vs held-out score.

Per run: total_tokens_in / total_tokens_out / wall_clock_sec from the scored
results row; api_equivalent_cost_usd from the row or the run's summary.json
(Claude Code runs only: Claude Code reports a list-price estimate, the Codex
CLI reports no cost; total_cost_usd is 0.0 for all 36 runs because every run
used a subscription). Held-out score: holdout_geomean_iter_s.

Token caveat (from the transcripts, see transcripts.py): the Codex CLI reports
usage only in its final `turn.completed` event, so a Codex session killed by
the harness watchdog (20 min hypothesis, 30 min implementation) adds 0 tokens
to the run's total. The table reports the number of killed sessions per run
and an adjusted total that imputes each killed session as the median finished
session of the same system and role (a rough correction, likely still low:
killed sessions ran to the time limit). Claude Code sessions killed early are
recovered from per-message usage by the runner (telemetry.py), so Claude
totals need no adjustment.

Spearman rho with a permutation p-value: pooled over the 36 runs, stratified
(ranks taken within each system, which removes system-level differences),
and within each system (n = 6, exact permutation p).
"""
from __future__ import annotations

import json
import statistics

import common as c
import transcripts as t


def main():
    rows = c.load_scored_rows()
    sessions = [s for s in t.build_cache() if s["role"] in ("hypothesis", "implementation", "scribe")]

    # median finished-session tokens per (system, role), for the imputation
    med = {}
    for m in c.MODELS:
        for role in ("hypothesis", "implementation", "scribe"):
            fin = [s for s in sessions if s["model"] == m and s["role"] == role and s["finished"]]
            med[(m, role)] = (statistics.median(s["tokens_in"] for s in fin),
                              statistics.median(s["tokens_out"] for s in fin))

    runs = []
    for m in c.MODELS:
        for r in c.REPS:
            row = rows[(m, r)]
            cost = row.get("api_equivalent_cost_usd")
            if cost is None:
                summ = json.loads((c.run_dir(m, r) / "summary.json").read_text())
                cost = summ.get("api_equivalent_cost_usd")
            ss = [s for s in sessions if s["model"] == m and s["rep"] == r]
            killed = [s for s in ss if not s["finished"] and s["tokens_in"] == 0]
            add_in = sum(med[(m, s["role"])][0] for s in killed)
            add_out = sum(med[(m, s["role"])][1] for s in killed)
            by_role = {role: {"tokens_in": sum(s["tokens_in"] for s in ss if s["role"] == role),
                              "tokens_out": sum(s["tokens_out"] for s in ss if s["role"] == role)}
                       for role in ("hypothesis", "implementation", "scribe")}
            runs.append({
                "system": c.NAME[m], "model": m, "rep": r, "cli": c.CLI[m],
                "tokens_in": row["total_tokens_in"], "tokens_out": row["total_tokens_out"],
                "tokens_in_from_transcripts": sum(s["tokens_in"] for s in ss),
                "tokens_out_from_transcripts": sum(s["tokens_out"] for s in ss),
                "sessions_killed_without_usage": len(killed),
                "killed_by_role": {role: sum(1 for s in killed if s["role"] == role)
                                   for role in ("hypothesis", "implementation", "scribe")},
                "tokens_in_adjusted": row["total_tokens_in"] + add_in,
                "tokens_out_adjusted": row["total_tokens_out"] + add_out,
                "tokens_by_role": by_role,
                "wall_clock_h": row["wall_clock_sec"] / 3600.0,
                "api_equivalent_cost_usd": cost,
                "total_cost_usd": row.get("total_cost_usd"),
                "holdout": row["holdout_geomean_iter_s"],
                "coremark_final": row.get("final_fitness"),
            })

    metrics = [("tokens_in", "input tokens (M)", 1e-6), ("tokens_out", "output tokens (M)", 1e-6),
               ("tokens_in_adjusted", "input tokens, killed Codex sessions imputed (M)", 1e-6),
               ("tokens_out_adjusted", "output tokens, killed Codex sessions imputed (M)", 1e-6),
               ("wall_clock_h", "wall clock (h)", 1.0)]

    corr = {}
    for key, _, _ in metrics:
        xs = [x[key] for x in runs]
        ys = [x["holdout"] for x in runs]
        groups = [([x[key] for x in runs if x["model"] == m], [x["holdout"] for x in runs if x["model"] == m])
                  for m in c.MODELS]
        corr[key] = {
            "pooled_36": c.spearman(xs, ys),
            "stratified_within_system": c.stratified_spearman(groups),
            "per_system": {c.NAME[m]: c.spearman(g[0], g[1]) for m, g in zip(c.MODELS, groups)},
        }
    claude = [x for x in runs if x["api_equivalent_cost_usd"] is not None]
    cgroups = [([x["api_equivalent_cost_usd"] for x in claude if x["model"] == m],
                [x["holdout"] for x in claude if x["model"] == m]) for m in c.MODELS[:2]]
    corr["api_equivalent_cost_usd"] = {
        "pooled_12_claude": c.spearman([x["api_equivalent_cost_usd"] for x in claude], [x["holdout"] for x in claude]),
        "stratified_within_system": c.stratified_spearman(cgroups),
        "per_system": {c.NAME[m]: c.spearman(g[0], g[1]) for m, g in zip(c.MODELS[:2], cgroups)},
    }

    per_sys = {}
    for m in c.MODELS:
        rs = [x for x in runs if x["model"] == m]
        d = {}
        for key, _, _ in metrics + [("api_equivalent_cost_usd", "", 1.0), ("holdout", "", 1.0),
                                    ("sessions_killed_without_usage", "", 1.0)]:
            vals = [x[key] for x in rs if x[key] is not None]
            d[key] = {"median": statistics.median(vals), "min": min(vals), "max": max(vals)} if vals else None
        tot_in = sum(x["tokens_in"] for x in rs)
        d["share_tokens_in_by_role"] = {role: sum(x["tokens_by_role"][role]["tokens_in"] for x in rs) / tot_in
                                        for role in ("hypothesis", "implementation", "scribe")}
        d["holdout_per_M_output_tokens"] = statistics.median(x["holdout"] / (x["tokens_out"] / 1e6) for x in rs)
        per_sys[c.NAME[m]] = d

    data = {"runs": runs, "per_system": per_sys, "spearman_vs_holdout": corr, "notes": __doc__}

    def mr(d, scale=1.0, nd=1):
        if d is None:
            return "n/a"
        return f"{d['median'] * scale:,.{nd}f} ({d['min'] * scale:,.{nd}f} to {d['max'] * scale:,.{nd}f})"

    L = ["# Analysis 1: effort vs held-out score", "",
         "Per system: median (min to max) over its 6 runs. Tokens are gross (input includes cache reads; "
         "output includes reasoning). API-equivalent cost exists only for Claude Code runs; every run's billed "
         "cost (total_cost_usd) is 0 because all runs used subscriptions.", ""]
    hdr = ["system", "input tokens (M)", "output tokens (M)", "wall clock (h)", "API-equivalent cost (USD)",
           "Codex sessions killed without usage", "held-out iter/s"]
    body = []
    for name, d in per_sys.items():
        body.append([name, mr(d["tokens_in"], 1e-6), mr(d["tokens_out"], 1e-6, 2), mr(d["wall_clock_h"]),
                     mr(d["api_equivalent_cost_usd"], 1.0, 0), mr(d["sessions_killed_without_usage"], 1.0, 0),
                     mr(d["holdout"], 1.0, 0)])
    L += [c.md_table(hdr, body), ""]
    L += ["Share of input tokens by agent role (summed over the 6 runs):", ""]
    body = [[name, *(f"{100 * d['share_tokens_in_by_role'][r]:.0f}%" for r in ("hypothesis", "implementation", "scribe"))]
            for name, d in per_sys.items()]
    L += [c.md_table(["system", "hypothesis", "implementation", "scribe"], body), ""]
    L += ["Adjusted totals (killed Codex sessions imputed at the median finished session of the same system and role):", ""]
    body = [[name, mr(d["tokens_in_adjusted"], 1e-6), mr(d["tokens_out_adjusted"], 1e-6, 2)] for name, d in per_sys.items()]
    L += [c.md_table(["system", "input tokens (M), adjusted", "output tokens (M), adjusted"], body), ""]

    rp = c.fmt_rho
    L += ["Spearman rho between effort and held-out score (permutation p-value):", ""]
    hdr = ["metric", "pooled, 36 runs", "within-system ranks, 36 runs"] + [c.NAME[m] for m in c.MODELS]
    body = []
    for key, label, _ in metrics:
        cc = corr[key]
        body.append([label, rp(cc["pooled_36"]), rp(cc["stratified_within_system"])] +
                    [rp(cc["per_system"][c.NAME[m]]) for m in c.MODELS])
    cc = corr["api_equivalent_cost_usd"]
    body.append(["API-equivalent cost (Claude runs only; pooled = 12 runs)", rp(cc["pooled_12_claude"]),
                 rp(cc["stratified_within_system"])] +
                [rp(cc["per_system"][c.NAME[m]]) for m in c.MODELS[:2]] + ["n/a"] * 4)
    L += [c.md_table(hdr, body), ""]
    L += ["Per run:", ""]
    hdr = ["system", "rep", "input (M)", "output (M)", "killed Codex sessions", "wall (h)", "API-eq. cost", "held-out"]
    body = [[x["system"], x["rep"], f"{x['tokens_in'] / 1e6:.1f}", f"{x['tokens_out'] / 1e6:.2f}",
             x["sessions_killed_without_usage"], f"{x['wall_clock_h']:.1f}",
             "" if x["api_equivalent_cost_usd"] is None else f"{x['api_equivalent_cost_usd']:.0f}",
             f"{x['holdout']:.0f}"] for x in runs]
    L += [c.md_table(hdr, body), ""]
    c.write_outputs("a1_effort", data, "\n".join(L))


if __name__ == "__main__":
    main()
