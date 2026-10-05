#!/usr/bin/env python3
"""Amendment 15 part A (with amendment 16): the random-mutation control on
harness 2.8.4. Descriptive.

Per slot: the gate outcome (bench/v2/random-mutation-v2/rep<N>/log.jsonl)
joined with the agent's mutation record (the archived agent log,
agent.full.log.gz: each mutation's file, line, operator and text, draws used,
lint result, seed material). Reports accepted / rejected / broken by first
failing gate, mutation operators, k and draws, distinct mutation sets, and for
every slot that passed formal, which of its mutations formal could not see:
lines inside the non-ALTOPS branch of an `ifdef RISCV_FORMAL_ALTOPS` block,
or assigning a signal read only there (the real multiplier and divider,
replaced by stand-in formulas under formal). A mutation that changes only a
trailing `//` comment is flagged comment-only (the operators skip whole-line
comments, not trailing ones).

    python3 -B research/v2/scripts/analyze_random.py [--json out.json] > out.md
"""
from __future__ import annotations

import argparse
import collections
import gzip
import json
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
V2 = REPO / "bench/v2"
MODEL = "random-mutation-v2"
FILES = {1: "results-rand-a.jsonl", 2: "results-rand-b.jsonl", 3: "results-rand-c.jsonl"}
TAG = "hwe-bench-v2.8.4"
REC = re.compile(r"=== \S*impl\.(hyp-\S+?)\.log ===\nRandom-mutation control \(no LLM\)\. Seeded mutations "
                 r"applied:\n(.*?)\nDraws used: (\d+)/\d+; final lint: (\w+)\.\nSeed material: (\S+); k=(\d)", re.S)
MUT = re.compile(r"^- (\S+):(\d+) \[(op_swap|ternary_swap|lit_perturb)\] (['\"])(.*)\4 -> (['\"])(.*)\6$")
ASSIGN = re.compile(r"^\s*(?:assign\s+)?([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=[^=]")


def altops_real_lines() -> dict[str, set[int]]:
    """Per V0 file, the line numbers formal never sees: the non-ALTOPS
    branch of every `ifdef RISCV_FORMAL_ALTOPS` / `ifndef` block."""
    out: dict[str, set[int]] = {}
    names = subprocess.run(["git", "-C", str(REPO), "ls-tree", "--name-only", f"{TAG}:cores/bench/rtl"],
                           check=True, capture_output=True, text=True).stdout.split()
    for n in names:
        src = subprocess.run(["git", "-C", str(REPO), "show", f"{TAG}:cores/bench/rtl/{n}"],
                             check=True, capture_output=True, text=True).stdout.splitlines()
        hidden, stack = set(), []
        for i, line in enumerate(src, 1):
            s = line.strip()
            if s.startswith("`ifdef RISCV_FORMAL_ALTOPS"):
                stack.append("altops_first")
            elif s.startswith("`ifndef RISCV_FORMAL_ALTOPS"):
                stack.append("real_first")
            elif s.startswith("`ifdef") or s.startswith("`ifndef"):
                stack.append("other")
            elif s.startswith("`else") and stack:
                stack[-1] = {"altops_first": "real_second", "real_first": "altops_second"}.get(stack[-1], stack[-1])
            elif s.startswith("`endif") and stack:
                stack.pop()
            elif any(x in ("real_first", "real_second") for x in stack):
                hidden.add(i)
        # Signals assigned outside the block but read only inside its
        # non-ALTOPS branch (V0's mul_uu, mul_ss, mul_su) are just as blind.
        code = [l.split("//")[0] for l in src]
        for i, line in enumerate(code, 1):
            m = ASSIGN.match(line)
            if not m or i in hidden:
                continue
            name = m.group(1)
            uses = [j for j, l in enumerate(code, 1) if j != i and re.search(rf"\b{name}\b", l)]
            reads = [j for j in uses if not re.match(rf"^\s*(logic|reg|wire)\b.*\b{name}\b\s*;", code[j - 1])
                     and not ASSIGN.match(code[j - 1]) or (ASSIGN.match(code[j - 1]) and
                     ASSIGN.match(code[j - 1]).group(1) != name)]
            if reads and all(j in hidden for j in reads):
                hidden.add(i)
        out[f"cores/bench/rtl/{n}"] = hidden
    return out


def comment_only(old: str, new: str) -> bool:
    return old.split("//")[0] == new.split("//")[0]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()
    hidden = altops_real_lines()
    slots, rows = [], {}
    for rep, f in FILES.items():
        rows[rep] = [json.loads(l) for l in (V2 / f).read_text().splitlines() if l.strip()][-1]
        log = [json.loads(l) for l in (V2 / MODEL / f"rep{rep}" / "log.jsonl").read_text().splitlines() if l.strip()]
        text = gzip.open(V2 / MODEL / f"rep{rep}" / "agent.full.log.gz", "rt").read()
        recs = {m.group(1): m for m in REC.finditer(text)}
        for x in log:
            if x["id"].startswith("baseline"):
                continue
            m = recs.get(x["id"])
            muts = [MUT.match(l).groups() for l in m.group(2).splitlines() if MUT.match(l)] if m else []
            if m:
                assert len(muts) == int(m.group(6)), (x["id"], m.group(2))
            gate = (x.get("error") or "").split(":")[0] if x["outcome"] == "broken" else x["outcome"]
            slots.append({"rep": rep, "id": x["id"], "gate": gate,
                          "detail": (x.get("error") or "").split("\n")[0][:80],
                          "fitness": x.get("fitness"), "fmax": x.get("fmax_mhz"),
                          "draws": int(m.group(3)) if m else None, "lint": m.group(4) if m else None,
                          "seed": m.group(5) if m else None, "k": int(m.group(6)) if m else None,
                          "mutations": [{"file": a, "line": int(b), "op": c, "old": d, "new": e,
                                         "formal_blind": int(b) in hidden.get(a, set()),
                                         "comment_only": comment_only(d, e)}
                                        for a, b, c, _, d, _, e in muts]})

    print("# Random-mutation control on harness 2.8.4 (amendment 15 part A, amendment 16)\n")
    print("| run | seed | slots | accepted | rejected (passed every gate) | broken: formal | broken: cosim | "
          "other | final CoreMark | held-out |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    tot = collections.Counter()
    for rep in FILES:
        ss = [s for s in slots if s["rep"] == rep]
        c = collections.Counter(s["gate"] for s in ss)
        tot.update(c)
        r = rows[rep]
        other = len(ss) - c["formal_failed"] - c["cosim_failed"] - c["regression"] - c["improvement"]
        print(f"| rep{rep} | {100 + rep} | {len(ss)} | {c['improvement']} | {c['regression']} | "
              f"{c['formal_failed']} | {c['cosim_failed']} | {other} | {r['final_fitness']} | "
              f"{r['holdout_geomean_iter_s']:.0f} |")
    n = len(slots)
    print(f"| all | | {n} | {tot['improvement']} | {tot['regression']} | {tot['formal_failed']} | "
          f"{tot['cosim_failed']} | {n - sum(tot[g] for g in ('formal_failed', 'cosim_failed', 'regression', 'improvement'))} | | |")

    recs = [s for s in slots if s["seed"]]
    sets = {tuple((m["file"], m["line"], m["new"]) for m in s["mutations"]) for s in recs}
    print(f"\nMutation records: {len(recs)} of {n} slots; distinct seed materials "
          f"{len(set(s['seed'] for s in recs))}; distinct edit sets {len(sets)}; "
          f"all lint-clean: {all(s['lint'] == 'pass' for s in recs)}.")
    print(f"k (mutations per slot): {dict(sorted(collections.Counter(s['k'] for s in recs).items()))}; "
          f"draws used: {dict(sorted(collections.Counter(s['draws'] for s in recs).items()))}.")
    ops = collections.Counter(m["op"] for s in recs for m in s["mutations"])
    files = collections.Counter(m["file"].split("/")[-1] for s in recs for m in s["mutations"])
    print(f"Operators: {dict(ops)}. Files: {dict(files.most_common())}.")
    fd = collections.Counter(s["detail"].split(":")[1].strip() for s in slots
                             if s["gate"] == "formal_failed" and ":" in s["detail"])
    print(f"First failing formal check: {dict(fd.most_common(8))} ...")

    print("\n## Slots that passed formal\n")
    print("| run | slot | gate | CoreMark | mutations (formal-blind ones marked *) |")
    print("|---|---|---|---|---|")
    for s in slots:
        if s["gate"] in ("formal_failed",):
            continue
        ms = "; ".join(f"{m['file'].split('/')[-1]}:{m['line']} {m['op']}{'*' if m['formal_blind'] else ''}"
                       f"{' (comment only)' if m['comment_only'] else ''} "
                       f"`{m['old'].strip()[:50]}` -> `{m['new'].strip()[:50]}`" for m in s["mutations"])
        print(f"| rep{s['rep']} | {s['id'].split('-')[-1]} | {s['gate']} | {s['fitness'] if s['gate'] != 'cosim_failed' else ''} "
              f"| {ms} |")
    passed = [s for s in slots if s["gate"] != "formal_failed"]
    blind = [s for s in passed if any(m["formal_blind"] for m in s["mutations"])]
    print(f"\n{len(blind)} of the {len(passed)} formal-passing slots contain a mutation in the real "
          f"multiplier/divider path that formal (ALTOPS) never sees.")
    co = [s for s in recs if s["mutations"] and all(m["comment_only"] for m in s["mutations"])]
    cm = sum(m["comment_only"] for s in recs for m in s["mutations"])
    cos = [s for s in passed if s["gate"] == "cosim_failed"]
    print(f"Cosim caught {len(cos)} formal-passing slots: {sum(s in blind for s in cos)} with a formal-blind "
          f"mutation, {len(cos) - sum(s in blind for s in cos)} without (their edits are in the table).")
    print(f"{cm} of {sum(len(s['mutations']) for s in recs)} mutations edit only a trailing comment; "
          f"{len(co)} slots are comment-only edits (no RTL change), outcomes "
          f"{dict(collections.Counter(s['gate'] for s in co))}.")
    if args.json:
        args.json.write_text(json.dumps({"slots": slots, "rows": {k: {kk: v.get(kk) for kk in (
            "status", "harness_version", "fixture_commit", "final_fitness", "holdout_geomean_iter_s",
            "wall_clock_sec")} for k, v in rows.items()}}, indent=1) + "\n")


if __name__ == "__main__":
    main()
