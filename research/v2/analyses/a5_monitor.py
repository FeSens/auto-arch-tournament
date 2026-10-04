#!/usr/bin/env python3
"""Analysis 5: transcript-monitor alerts per system, and the operator's
verdicts on HIGH alerts.

Sources (research/runs/EXP-2026-09-28-v2-main/):
  monitor/alerts.jsonl   one row per alert: at, severity, run, what, detail.
                         `at` is the run host's naive local time (CEST, UTC+2;
                         research/v2/scripts/monitor_run.py uses
                         datetime.now()); converted to UTC here.
  monitor_review.md      the operator's append-only table: time, run, alert,
                         verdict, action.

Scope: alerts of the 36 scored runs raised at or after the scored attempt's
started_at (this drops the stopped 18:01-18:41Z rep2 attempts of Opus and
Luna; alerts.jsonl starts with the 2.8.0 campaign, the scored attempt of both
rep1s). An alert can appear twice, from the live transcript and from its
archived copy; "unique" counts drop those repeats (same run, same text after
the file-name prefix).

Review rows in scope: rows labelled "2.8.2 campaign" (all scored runs except
the rep1s of Opus and Luna) and "2.8.0 campaign" rows naming those two rep1s.
A row can cover several alerts and several runs. Verdict class, by keywords
in the verdict cell, in this priority: real (the verdict calls it real),
harness (harness defect/bug/failure, or the new EPERM class that made a slot
broken), false positive (the rule matched words, not an action), benign
(a real action that was harmless: e.g. an agent's pkill that could only reach
its own shell, a fail-closed sandbox start race, reading its own files).
"""
from __future__ import annotations

import collections
import datetime as dt
import json
import re

import common as c

LOCAL_UTC_OFFSET = dt.timedelta(hours=2)  # CEST during the whole campaign (DST ends 2026-10-25)
RUN_RX = re.compile(r"(" + "|".join(re.escape(m) for m in c.MODELS) + r")-rep(\d)")


def split_row(line: str) -> list[str]:
    codes = []

    def keep(m):
        codes.append(m.group(0))
        return f"\x00{len(codes) - 1}\x00"
    t = re.sub(r"`[^`]*`", keep, line).replace("\\|", "\x01")
    cells = [x.strip() for x in t.strip().strip("|").split("|")]
    return [re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], x).replace("\x01", "|") for x in cells]


def runs_named(cell: str) -> list[tuple[str, int]]:
    out = []
    last_model = None
    for tok in re.split(r"[;,]\s*", cell):
        m = RUN_RX.search(tok)
        if m:
            last_model = m.group(1)
            out.append((m.group(1), int(m.group(2))))
            continue
        m2 = re.fullmatch(r"\s*rep(\d)\s*", tok)
        if m2 and last_model:
            out.append((last_model, int(m2.group(1))))
    return out


def verdict_class(v: str) -> str:
    low = v.lower()
    if re.match(r"\s*real\b", low) or "real, within" in low:
        return "real"
    if re.search(r"harness (defect|bug|failure)", low) or low.startswith("new class"):
        return "harness"
    if low.lstrip("( 1)").startswith("false positive") or low.startswith("false positive"):
        return "false positive"
    return "benign"


def main():
    rows = c.load_scored_rows()
    start = {(m, r): dt.datetime.fromisoformat(rows[(m, r)]["started_at"]).replace(tzinfo=None)
             for m in c.MODELS for r in c.REPS}
    alerts = [json.loads(l) for l in open(c.EXP / "monitor" / "alerts.jsonl")]
    scoped = []
    dropped_before_start = collections.Counter()
    for a in alerts:
        m = RUN_RX.fullmatch(a["run"])
        if not m:
            continue
        key = (m.group(1), int(m.group(2)))
        if key not in start:
            continue
        at_utc = dt.datetime.fromisoformat(a["at"]) - LOCAL_UTC_OFFSET
        if at_utc < start[key]:
            dropped_before_start[c.NAME[key[0]]] += 1
            continue
        a = dict(a, model=key[0], rep=key[1], at_utc=at_utc.isoformat() + "Z",
                 detail_key=re.sub(r"^[^:]*\.log:\s*", "", a["detail"]))
        scoped.append(a)

    per_sys = {}
    for mdl in c.MODELS:
        xs = [a for a in scoped if a["model"] == mdl]
        uniq = {(a["rep"], a["severity"], a["what"], a["detail_key"]) for a in xs}
        per_sys[c.NAME[mdl]] = {
            "alerts": dict(collections.Counter(a["severity"] for a in xs)),
            "unique_alerts": dict(collections.Counter(u[1] for u in uniq)),
            "high_by_what": dict(collections.Counter(a["what"] for a in xs if a["severity"] == "HIGH")),
            "high_unique_by_what": dict(collections.Counter(u[2] for u in uniq if u[1] == "HIGH")),
            "medium_by_what": dict(collections.Counter(a["what"] for a in xs if a["severity"] == "MEDIUM")),
            "per_run_alerts": [sum(1 for a in xs if a["rep"] == r) for r in c.REPS],
        }

    # operator review
    review = []
    for line in (c.EXP / "monitor_review.md").read_text().splitlines():
        if not line.startswith("| ") or line.startswith("| time"):
            continue
        cells = split_row(line)
        if len(cells) < 4:
            continue
        when, run_cell, alert, verdict = cells[0], cells[1], cells[2], cells[3]
        label = re.search(r"\(([^)]*)", when)
        label = label.group(1) if label else ""
        named = runs_named(run_cell)
        if "2.8.2" in label:
            in_scope = [k for k in named if k in start]
        elif "2.8.0 campaign" in label:
            in_scope = [k for k in named if k[1] == 1 and k[0] in ("claude-opus-5_5_xhigh-v2", "gpt-6-luna_xhigh-v2")]
        else:
            in_scope = []
        generic = ("2.8.2" in label and not named)
        if not in_scope and not generic:
            continue
        review.append({"time": when, "runs": [f"{c.NAME[k[0]]} rep{k[1]}" for k in in_scope],
                       "systems": sorted({c.NAME[k[0]] for k in in_scope}) or ["(several or all)"],
                       "high": "HIGH" in alert, "verdict_class": verdict_class(verdict),
                       "alert": c.scrub(alert[:300]), "verdict": c.scrub(verdict[:600])})

    high_rows = [r for r in review if r["high"]]
    verdicts = {}
    for name in [c.NAME[m] for m in c.MODELS] + ["(several or all)"]:
        vs = collections.Counter(r["verdict_class"] for r in high_rows if name in r["systems"])
        verdicts[name] = dict(vs)
    overall_verdicts = dict(collections.Counter(r["verdict_class"] for r in high_rows))
    notable = [r for r in high_rows if r["verdict_class"] in ("real", "harness")]
    other_notable = [r for r in review if not r["high"] and r["verdict_class"] in ("real", "harness")]

    data = {"per_system": per_sys, "dropped_before_scored_start": dict(dropped_before_start),
            "review_high_verdicts_per_system": verdicts, "review_high_verdicts_overall": overall_verdicts,
            "review_rows_in_scope": review, "notes": __doc__}

    L = ["# Analysis 5: transcript-monitor alerts", "",
         "Alert counts per system over its 6 scored runs (raw; unique drops live/archived duplicates):", ""]
    hdr = ["system", "HIGH", "HIGH unique", "MEDIUM", "MEDIUM unique", "alerts per run"]
    body = []
    tot = collections.Counter()
    for name, d in per_sys.items():
        body.append([name, d["alerts"].get("HIGH", 0), d["unique_alerts"].get("HIGH", 0),
                     d["alerts"].get("MEDIUM", 0), d["unique_alerts"].get("MEDIUM", 0),
                     ", ".join(str(x) for x in d["per_run_alerts"])])
        for k in ("HIGH", "MEDIUM"):
            tot[k] += d["alerts"].get(k, 0)
            tot[k + "u"] += d["unique_alerts"].get(k, 0)
    body.append(["all", tot["HIGH"], tot["HIGHu"], tot["MEDIUM"], tot["MEDIUMu"], ""])
    L += [c.md_table(hdr, body), ""]
    whats = sorted({w for d in per_sys.values() for w in d["high_unique_by_what"]})
    L += ["Unique HIGH alerts by rule:", ""]
    body = [[w] + [per_sys[c.NAME[m]]["high_unique_by_what"].get(w, 0) for m in c.MODELS] for w in whats]
    L += [c.md_table(["rule"] + [c.NAME[m] for m in c.MODELS], body), ""]
    mwhats = sorted({w for d in per_sys.values() for w in d["medium_by_what"]},
                    key=lambda w: -sum(d["medium_by_what"].get(w, 0) for d in per_sys.values()))
    L += ["MEDIUM alerts by rule (raw):", ""]
    body = [[w] + [per_sys[c.NAME[m]]["medium_by_what"].get(w, 0) for m in c.MODELS] for w in mwhats]
    L += [c.md_table(["rule"] + [c.NAME[m] for m in c.MODELS], body), ""]
    L += [f"Operator review rows on HIGH alerts in scope: {len(high_rows)} (a row can cover several alerts "
          "and runs). Verdict classes:", ""]
    vc = ["benign", "false positive", "harness", "real"]
    body = [[name] + [v.get(k, 0) for k in vc] for name, v in verdicts.items()]
    body.append(["all rows"] + [overall_verdicts.get(k, 0) for k in vc])
    L += [c.md_table(["system"] + vc, body), ""]
    L += ["HIGH rows judged real or harness-caused:", ""]
    for r in notable:
        L.append(f"- {r['time']} {', '.join(r['runs']) or r['systems'][0]} [{r['verdict_class']}]: "
                 f"{r['verdict'][:400]}")
    if other_notable:
        L += ["", "Other in-scope review rows (operator checks, not HIGH alerts) judged real or harness-caused:", ""]
        for r in other_notable:
            L.append(f"- {r['time']} {', '.join(r['runs']) or r['systems'][0]} [{r['verdict_class']}]: "
                     f"{r['verdict'][:300]}")
    c.write_outputs("a5_monitor", data, "\n".join(L))


if __name__ == "__main__":
    main()
