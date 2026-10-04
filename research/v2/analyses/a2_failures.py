#!/usr/bin/env python3
"""Analysis 2: where candidates end, per system.

Every candidate row of the 36 runs' log.jsonl (45 per run; the round-0
baseline retest is excluded) gets one outcome class:

  accepted                  the round's winner, merged as the new champion
  rejected_lost_to_sibling  passed every gate and beat the champion by more than
                            the 4.6% margin, but another slot of the same round
                            scored higher (only one winner per round)
  rejected_below_margin     passed every gate, improved, but by 4.6% or less
  rejected_no_gain          passed every gate, did not improve on the champion
  broken classes, in the gate order of tools/tournament.py:run_slot:
    hypothesis_gen_failed   the hypothesis agent wrote no valid hypothesis file
    implementation_compile_failed / build_failed / sandbox_violation
    formal_check_failed     riscv-formal found a counterexample (or a check errored)
    formal_timeout          run_all.sh exceeded the harness's 2,700 s limit
    cosim_failed            retired instructions differ from the Python ISS
    placement_failed        Gowin place and route failed (design does not fit
                            the Tang Nano 20K or does not route)
    coremark_failed         CoreMark on the FPGA model failed validation
"""
from __future__ import annotations

import collections

import common as c

ORDER = ["accepted", "rejected_lost_to_sibling", "rejected_below_margin", "rejected_no_gain",
         "hypothesis_gen_failed", "schema_error", "implementation_compile_failed", "sandbox_violation",
         "build_failed", "formal_ch0_precheck", "formal_check_failed", "formal_timeout", "cosim_failed",
         "placement_failed", "coremark_failed", "fpga_report_unparsed"]
BROKEN = ORDER[4:]


def main():
    rows = c.load_scored_rows()
    per_sys = {}
    per_run = []
    details = []
    for m in c.MODELS:
        cnt = collections.Counter()
        for r in c.REPS:
            rc = collections.Counter()
            for d in c.candidates(m, r):
                cls = c.outcome_class(d)
                rc[cls] += 1
                if cls in BROKEN:
                    details.append({"system": c.NAME[m], "rep": r, "id": d["id"], "class": cls,
                                    "error_head": c.scrub((d.get("error") or "").split("\n")[0][:160])})
            cnt += rc
            # consistency with the results row (accepted there counts the baseline)
            row = rows[(m, r)]
            per_run.append({"system": c.NAME[m], "rep": r, **{k: rc.get(k, 0) for k in ORDER},
                            "results_row_accepted_minus_baseline": row["accepted"] - 1,
                            "results_row_rejected": row["rejected"], "results_row_broken": row["broken"],
                            "results_row_broken_by_class": row.get("broken_by_class")})
        per_sys[c.NAME[m]] = {k: cnt.get(k, 0) for k in ORDER}
        unknown = set(cnt) - set(ORDER)
        if unknown:
            raise SystemExit(f"unknown classes {unknown}")
    overall = collections.Counter()
    for v in per_sys.values():
        overall.update(v)
    per_sys_all = dict(per_sys, all=dict(overall))

    # consistency checks against the results rows
    problems = []
    for pr in per_run:
        acc = pr["accepted"]
        rej = pr["rejected_lost_to_sibling"] + pr["rejected_below_margin"] + pr["rejected_no_gain"]
        brk = sum(pr[k] for k in BROKEN)
        if acc != pr["results_row_accepted_minus_baseline"]:
            problems.append(f"{pr['system']} rep{pr['rep']}: accepted {acc} vs row {pr['results_row_accepted_minus_baseline']}")
        if rej != pr["results_row_rejected"] or brk - pr["placement_failed"] != pr["results_row_broken"]:
            problems.append(f"{pr['system']} rep{pr['rep']}: rejected {rej} / broken {brk - pr['placement_failed']} "
                            f"vs row {pr['results_row_rejected']} / {pr['results_row_broken']}")

    stage_counts = collections.Counter()
    for k in BROKEN:
        stage_counts[c.STAGE_OF[k]] += overall.get(k, 0)

    data = {"per_system": per_sys_all, "per_run": per_run, "gate_failures": details,
            "failures_by_stage": dict(stage_counts), "consistency_problems": problems, "notes": __doc__}

    L = ["# Analysis 2: where candidates end", "",
         "45 candidates per run (15 rounds x 3 slots), 270 per system, 1,620 overall. "
         "Counts, with the share of the system's candidates in parentheses.", ""]
    shown = [k for k in ORDER if overall.get(k, 0) > 0]
    hdr = ["system"] + shown + ["gate failures"]
    body = []
    for name, v in per_sys_all.items():
        n = sum(v.values())
        fails = sum(v.get(k, 0) for k in BROKEN)
        body.append([name] + [f"{v.get(k, 0)} ({100 * v.get(k, 0) / n:.1f}%)" for k in shown] +
                    [f"{fails} ({100 * fails / n:.1f}%)"])
    L += [c.md_table(hdr, body), ""]
    L += ["Gate failures by the stage that stopped them (all systems):", ""]
    tot = sum(stage_counts.values())
    body = [[s, n, f"{100 * n / tot:.0f}%"] for s, n in sorted(stage_counts.items()) if n]
    L += [c.md_table(["stage", "candidates", "share of gate failures"], body), ""]
    L += ["Gate failures by stage per system:", ""]
    stages = sorted({c.STAGE_OF[k] for k in BROKEN if overall.get(k, 0)})
    body = []
    for name, v in per_sys.items():
        sc = collections.Counter()
        for k in BROKEN:
            sc[c.STAGE_OF[k]] += v.get(k, 0)
        body.append([name] + [sc.get(s, 0) for s in stages])
    L += [c.md_table(["system"] + stages, body), ""]
    if problems:
        L += ["Consistency problems against the results rows:", ""] + [f"- {p}" for p in problems] + [""]
    else:
        L += ["Check: per-run counts match every results row. The results rows count the baseline retest as "
              "accepted and count placement_failed candidates as neither rejected nor broken "
              "(accepted + rejected + broken = 46 minus placement failures); here placement_failed is a gate failure.", ""]
    c.write_outputs("a2_failures", data, "\n".join(L))


if __name__ == "__main__":
    main()
