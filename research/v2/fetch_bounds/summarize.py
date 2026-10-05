#!/usr/bin/env python3
"""Summarize the fetch-bounds results at one depth: per system, how many
finals pass, fail (with the failing step and fetch-address trace) or time out
(with the last step proven free of a counterexample).

    python3 -B research/v2/fetch_bounds/summarize.py [--depth 20] > results/summary-d20.md
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SYSTEMS = [("claude-opus-5_5_xhigh-v2_", "Opus 5.5"), ("claude-sonnet-5-5_xhigh-v2_", "Sonnet 5.5"),
           ("gpt-6_1-sol_xhigh-v2_", "GPT-6.1 Sol"), ("gpt-6-astra_xhigh-v2_", "GPT-6 Astra"),
           ("gpt-5_5_xhigh-v2_", "GPT-5.5"), ("gpt-6-luna_xhigh-v2_", "GPT-6 Luna"),
           ("gpt-6_1-sol_xhigh-v2-nolessons_", "GPT-6.1 Sol, no lessons (ablation)"),
           ("gpt-6-sol_xhigh-v2_", "GPT-6 Sol pilot (unscored)"), ("textbook", "textbook edit")]


def system(name: str) -> str:
    for prefix, label in SYSTEMS:
        if name.startswith(prefix):
            return label
    return name


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--depth", type=int, default=20)
    a = ap.parse_args()
    recs = [json.loads(p.read_text()) for p in sorted((HERE / "results").glob(f"*-d{a.depth}.json"))]
    by = collections.defaultdict(list)
    for r in recs:
        by[system(r["design"])].append(r)
    print(f"# Fetch-address bounds, BMC depth {a.depth}\n")
    print("| system | designs | PASS | FAIL | TIMEOUT | solver time, median s |")
    print("|---|---|---|---|---|---|")
    tot = collections.Counter()
    for _, label in SYSTEMS:
        rs = by.get(label, [])
        if not rs:
            continue
        c = collections.Counter(r["outcome"] for r in rs)
        tot.update(c)
        secs = sorted(r["seconds"] for r in rs if r["outcome"] == "PASS")
        med = secs[len(secs) // 2] if secs else ""
        print(f"| {label} | {len(rs)} | {c['PASS']} | {c['FAIL']} | {c['TIMEOUT']} | {med} |")
    print(f"| all | {len(recs)} | {tot['PASS']} | {tot['FAIL']} | {tot['TIMEOUT']} | |")
    other = [r for r in recs if r["outcome"] not in ("PASS", "FAIL", "TIMEOUT")]
    if other:
        print(f"\nOther outcomes: {[(r['design'], r['outcome']) for r in other]}")
    print("\n## Not passing\n")
    print("| design | outcome | step | fetch addresses (FAIL) or steps with no counterexample (TIMEOUT) |")
    print("|---|---|---|---|")
    for r in recs:
        if r["outcome"] == "FAIL":
            print(f"| {r['design']} | FAIL | {r.get('fail_step')} | {' '.join(r.get('imem_addr_trace', []))} |")
        elif r["outcome"] == "TIMEOUT":
            print(f"| {r['design']} | TIMEOUT after {r['seconds']} s | | 0 to {r.get('no_cex_through_step')} |")


if __name__ == "__main__":
    main()
