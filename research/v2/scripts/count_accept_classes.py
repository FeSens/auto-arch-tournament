#!/usr/bin/env python3
"""Keyword count of accepted design classes in the V2 campaign logs (paper
section 5a, security caveat): accepted rounds whose title or first 600
characters of hypothesis match each pattern. 37 runs: 36 scored plus the
GPT-6 Sol pilot; the no-lessons ablation is not matched by the glob.

    python3 -B research/v2/scripts/count_accept_classes.py
"""
import json, re, glob
pats = {"early-exit/variable-latency divider": r"early[- ](exit|out|termination|terminat)|variable[- ]latency|skip leading|leading[- ]zero",
        "branch predictor/BTB": r"predict|BTB|branch target buffer",
        "cache / fetch buffer / loop buffer": r"cache|fetch buffer|prefetch|loop buffer|replay",
        "iterative/multi-cycle divider": r"iterative|radix|multi-?cycle div|sequential div"}
c = {k: 0 for k in pats}; runs = {k: set() for k in pats}; tot = 0
for f in glob.glob("bench/v2/*-v2/rep*/log.jsonl"):
    for l in open(f):
        try: x = json.loads(l)
        except Exception: continue
        if x.get("outcome") != "improvement": continue
        tot += 1
        h = x.get("hypothesis"); h = h if isinstance(h, str) else json.dumps(h)
        t = (x.get("title") or "") + " " + h[:600]
        for k, p in pats.items():
            if re.search(p, t, re.I): c[k] += 1; runs[k].add(f.split("/")[2] + "/" + f.split("/")[3])
print("accepted", tot)
for k in pats: print(k, c[k], "accepts in", len(runs[k]), "runs")
