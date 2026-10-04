#!/usr/bin/env python3
"""Analysis 4: the scribe's lessons.

Source: research/v2/lessons/all_lessons.jsonl (one row per lesson bullet,
restricted to the 36 scored runs), cross-checked against the `lesson` field
of each run's log.jsonl. The scribe (same model as the system) may write no
lesson for a candidate ("write nothing at all if no useful lesson can be
distilled"), so counts differ by system.

Topics: keyword regexes over the lesson text (case-insensitive), multi-label.
"primary topic" assigns each lesson to the topic whose keyword appears first
in the text (a lesson usually opens with its subject), among the specific
topics; the generic ones (area / resources, Fmax / critical path: nearly
every lesson mentions Fmax, since fitness = Fmax x CoreMark iterations per
cycle) count only when no specific topic matches. The leading
"- <date> <id> (<outcome>, <delta>):" prefix is removed before matching.

Repetition: within a run, a hypothesis title "repeats" an earlier one when
the Jaccard similarity of their content-word sets (lowercased, stopwords and
1-2 letter words removed, light suffix stripping) is at least 0.5, the
earlier candidate was rejected or failed a gate in an earlier round, and the
scribe wrote a lesson for it. Sensitivity at 0.4 and 0.6 is reported.
"""
from __future__ import annotations

import collections
import json
import re

import common as c

TOPICS = [
    ("divider", r"\bdiv\w*|\brem[u]?\b|quotient|radix|\bsrt\b|non-?restoring|division"),
    ("multiplier", r"\bmul\w*|multipl\w*|\bdsps?\b|partial.product|booth"),
    ("branch prediction", r"predict\w*|\bbtb\b|\bbht\b|\bpht\b|\bras\b|return.address|gshare|backedge|\bbtfn\b|"
                          r"branch.target|\btaken\b|\bjal\b|\bjalr\b"),
    ("fetch / caches", r"\bfetch\w*|i-?cache|\bcache\w*|prefetch\w*|instruction.queue|loop.buffer|replay|"
                       r"\bimem\w*|\bfifo\b"),
    ("forwarding / hazards", r"forward\w*|bypass\w*|hazard\w*|load-use|interlock\w*|\bstall\w*|bubbles?\b|scoreboard"),
    ("formal / RVFI", r"formal|\brvfi\w*|liveness|\bsby\b|counterexample|pc_fwd|reg_ch0|_ch0\b|\bbmc\b|altops"),
    ("cosim", r"cosim|co-sim|\biss\b|reference.model|random\d?\.elf|selftest|istall|dstall"),
    ("process / tooling", r"placement.option|place.and.route|\bseeds?\b|noise|\bmargin\b|\bbar\b|qualif\w*|"
                          r"sandbox|time.?out|budget|\blint\b|verilator|yosys|harness|watchdog|run-to-run|spread"),
    ("area / resources", r"\blut4?s?\b|\bbsram\b|lut-?ram|\bdffs?\b|resource|\barea\b|does not fit|utiliz"),
    ("Fmax / critical path", r"fmax|critical|\bmhz\b|timing|slack|logic.levels?|\bcones?\b|fanout|\bpaths?\b"),
]
TOPIC_RX = [(n, re.compile(rx, re.I)) for n, rx in TOPICS]

SOURCE = {"improvement": "accepted", "regression": "rejected", "broken": "gate failure",
          "placement_failed": "gate failure"}

STOP = set("""a an the and or of to in on for with from by at into onto as is are be via per
use using uses add adds added make makes keep keeps move moves only one two three new old
than that this its it not no off out up down over under without between before after
cores bench core rtl stage stages unit""".split())

# Short quotes chosen by reading the lesson files (ids are stable across reruns).
QUOTE_IDS = [
    ("gpt-6_1-sol_xhigh-v2", 6, "hyp-20261002-002-r1s1"),
    ("claude-opus-5_5_xhigh-v2", 1, "hyp-20260929-002-r1s1"),
    ("gpt-6-luna_xhigh-v2", 5, "hyp-20260930-003-r2s2"),
    ("claude-sonnet-5-5_xhigh-v2", 3, "hyp-20261002-003-r9s2"),
    ("gpt-6-astra_xhigh-v2", 1, "hyp-20261001-002-r15s1"),
]


def norm_tokens(title: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", title.lower().replace("-", " "))
    out = set()
    for w in words:
        if len(w) <= 2 or w in STOP:
            continue
        for suf in ("ing", "ed", "es", "s"):
            if w.endswith(suf) and len(w) - len(suf) >= 4:
                w = w[: -len(suf)]
                break
        out.add(w)
    return out


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a | b else 0.0


GENERIC = ("area / resources", "Fmax / critical path")
PREFIX = re.compile(r"^-\s*\S+\s+\S+\s+\([^)]*\):\s*")


def lesson_body(text: str) -> str:
    return PREFIX.sub("", text.strip())


def topics_of(text: str) -> list[str]:
    """Matching topics; the first element is the primary topic."""
    t = lesson_body(text)
    hits = []
    for n, rx in TOPIC_RX:
        mm = rx.search(t)
        if mm:
            hits.append((n in GENERIC, mm.start(), n))
    return [n for _, _, n in sorted(hits)]


def main():
    lessons = [json.loads(l) for l in open(c.REPO / "research" / "v2" / "lessons" / "all_lessons.jsonl")]
    lessons = [x for x in lessons if x["model"] in c.MODELS and x["rep"] in c.REPS and not x.get("smoke")]

    # cross-check against log.jsonl
    problems = []
    log_lessons = {}
    cand = {}
    for m in c.MODELS:
        for r in c.REPS:
            for d in c.candidates(m, r):
                cand[(m, r, d["id"])] = d
                if d.get("lesson"):
                    log_lessons[(m, r, d["id"])] = d["lesson"]
    ids_all = collections.Counter((x["model"], x["rep"], x["id"]) for x in lessons)
    dup = [k for k, v in ids_all.items() if v > 1]
    only_file = set(ids_all) - set(log_lessons)
    only_log = set(log_lessons) - set(ids_all)
    if dup:
        problems.append(f"{len(dup)} candidates have more than one lesson row: {sorted(dup)[:5]}")
    if only_file:
        problems.append(f"{len(only_file)} lesson rows have no lesson in log.jsonl: {sorted(only_file)[:5]}")
    if only_log:
        problems.append(f"{len(only_log)} log.jsonl lessons are missing from all_lessons.jsonl: {sorted(only_log)[:5]}")

    # counts per run and source
    per_run = collections.Counter((x["model"], x["rep"]) for x in lessons)
    per_sys = {}
    for m in c.MODELS:
        xs = [x for x in lessons if x["model"] == m]
        src = collections.Counter(SOURCE.get(x["outcome"], x["outcome"]) for x in xs)
        # share of candidates of each outcome that got a lesson
        cands = [d for k, d in cand.items() if k[0] == m]
        got = collections.Counter()
        tot = collections.Counter()
        for d in cands:
            s = SOURCE.get(d["outcome"], d["outcome"])
            tot[s] += 1
            if (m, d["id"]) in {(x["model"], x["id"]) for x in xs if x["rep"]} and d.get("lesson"):
                got[s] += 1
        lesson_rate = {}
        for s in tot:
            n_got = sum(1 for d in cands if SOURCE.get(d["outcome"], d["outcome"]) == s and d.get("lesson"))
            lesson_rate[s] = n_got / tot[s]
        multi = collections.Counter()
        primary = collections.Counter()
        for x in xs:
            ts = topics_of(x["lesson"])
            multi.update(ts)
            primary[ts[0] if ts else "other"] += 1
        per_sys[c.NAME[m]] = {
            "n_lessons": len(xs),
            "per_run": [per_run[(m, r)] for r in c.REPS],
            "by_source": dict(src),
            "lesson_rate_by_candidate_outcome": lesson_rate,
            "topic_share_multilabel": {n: multi[n] / len(xs) for n, _ in TOPICS},
            "primary_topic_share": {n: primary[n] / len(xs) for n in [t for t, _ in TOPICS] + ["other"]},
            "median_chars": sorted(len(lesson_body(x["lesson"])) for x in xs)[len(xs) // 2],
        }
    all_multi = collections.Counter()
    all_primary = collections.Counter()
    for x in lessons:
        ts = topics_of(x["lesson"])
        all_multi.update(ts)
        all_primary[ts[0] if ts else "other"] += 1
    overall = {"n_lessons": len(lessons),
               "by_source": dict(collections.Counter(SOURCE.get(x["outcome"], x["outcome"]) for x in lessons)),
               "topic_share_multilabel": {n: all_multi[n] / len(lessons) for n, _ in TOPICS},
               "primary_topic_share": {n: all_primary[n] / len(lessons) for n in [t for t, _ in TOPICS] + ["other"]}}

    # repetition of earlier failed ideas
    def repeats(threshold):
        out = []
        for m in c.MODELS:
            for r in c.REPS:
                ds = sorted(c.candidates(m, r), key=lambda d: (d["round_id"], d["slot"]))
                toks = {d["id"]: norm_tokens(d.get("title") or "") for d in ds}
                for j in ds:
                    best = None
                    for i in ds:
                        if i["round_id"] >= j["round_id"]:
                            continue
                        if c.outcome_class(i) == "accepted" or not i.get("lesson"):
                            continue
                        s = jaccard(toks[i["id"]], toks[j["id"]])
                        if s >= threshold and (best is None or s > best[0]):
                            best = (s, i)
                    if best:
                        out.append({"system": c.NAME[m], "rep": r, "later_id": j["id"], "later_title": j["title"],
                                    "later_class": c.outcome_class(j), "earlier_id": best[1]["id"],
                                    "earlier_title": best[1]["title"], "earlier_class": c.outcome_class(best[1]),
                                    "rounds_apart": j["round_id"] - best[1]["round_id"],
                                    "jaccard": round(best[0], 2)})
        return out

    rep = {th: repeats(th) for th in (0.4, 0.5, 0.6)}
    n_later = {m: sum(1 for r in c.REPS for d in c.candidates(m, r) if d["round_id"] >= 2) for m in c.MODELS}
    title_words = {}
    for m in c.MODELS:
        lens = sorted(len(norm_tokens(d.get("title") or "")) for r in c.REPS for d in c.candidates(m, r))
        title_words[m] = lens[len(lens) // 2]
    rep_sys = {}
    for th, rows in rep.items():
        rep_sys[th] = {}
        for m in c.MODELS:
            rs = [x for x in rows if x["system"] == c.NAME[m]]
            outc = collections.Counter("accepted" if x["later_class"] == "accepted" else
                                       ("rejected" if x["later_class"].startswith("rejected") else "gate failure")
                                       for x in rs)
            rep_sys[th][c.NAME[m]] = {"n": len(rs), "of_later_candidates": n_later[m],
                                      "median_title_content_words": title_words[m],
                                      "share": len(rs) / n_later[m], "outcomes": dict(outc)}

    quotes = []
    by_key = {(x["model"], x["rep"], x["id"]): x for x in lessons}
    for k in QUOTE_IDS:
        if k in by_key:
            x = by_key[k]
            text = lesson_body(x["lesson"])
            short = text if len(text) <= 230 else text[:230].rsplit(" ", 1)[0].rstrip(",;:") + " ..."
            quotes.append({"system": c.NAME[k[0]], "rep": k[1], "id": k[2], "outcome": SOURCE[x["outcome"]],
                           "delta_pct": x.get("delta_pct"), "lesson": text, "short": short})

    data = {"per_system": per_sys, "overall": overall, "repetition": {str(k): v for k, v in rep_sys.items()},
            "repeat_pairs_0.5": rep[0.5], "quotes": quotes, "consistency_problems": problems,
            "topics_regex": dict(TOPICS), "notes": __doc__}

    p = lambda x: f"{100 * x:.0f}%"
    L = ["# Analysis 4: lessons", ""]
    hdr = ["system", "lessons", "per run", "from accepted", "from rejected", "from gate failures",
           "lesson written for: accepted / rejected / gate-failed candidates", "median length (chars)"]
    body = []
    for name, d in per_sys.items():
        lr = d["lesson_rate_by_candidate_outcome"]
        body.append([name, d["n_lessons"], ", ".join(str(v) for v in d["per_run"]),
                     d["by_source"].get("accepted", 0), d["by_source"].get("rejected", 0),
                     d["by_source"].get("gate failure", 0),
                     f"{p(lr.get('accepted', 0))} / {p(lr.get('rejected', 0))} / {p(lr.get('gate failure', 0))}",
                     d["median_chars"]])
    body.append(["all", overall["n_lessons"], "", overall["by_source"].get("accepted", 0),
                 overall["by_source"].get("rejected", 0), overall["by_source"].get("gate failure", 0), "", ""])
    L += [c.md_table(hdr, body), ""]
    L += ["Topic shares, multi-label (a lesson can count under several topics):", ""]
    names = [n for n, _ in TOPICS]
    body = [[name] + [p(d["topic_share_multilabel"][n]) for n in names] for name, d in per_sys.items()]
    body.append(["all"] + [p(overall["topic_share_multilabel"][n]) for n in names])
    L += [c.md_table(["system"] + names, body), ""]
    L += ["Primary topic (the specific topic named first in the lesson; generic topics only when nothing specific matches):", ""]
    names2 = names + ["other"]
    body = [[name] + [p(d["primary_topic_share"][n]) for n in names2] for name, d in per_sys.items()]
    body.append(["all"] + [p(overall["primary_topic_share"][n]) for n in names2])
    L += [c.md_table(["system"] + names2, body), ""]
    L += ["Later hypotheses (rounds 2 to 15) whose title closely matches an earlier rejected or gate-failed "
          "candidate that has a lesson (Jaccard of title word sets):", ""]
    body = []
    for m in c.MODELS:
        name = c.NAME[m]
        cells = [name, n_later[m]]
        for th in (0.4, 0.5, 0.6):
            d = rep_sys[th][name]
            cells.append(f"{d['n']} ({p(d['share'])})")
        cells.append(title_words[m])
        o = rep_sys[0.5][name]["outcomes"]
        cells.append(f"{o.get('accepted', 0)} / {o.get('rejected', 0)} / {o.get('gate failure', 0)}")
        body.append(cells)
    L += [c.md_table(["system", "later candidates", "J >= 0.4", "J >= 0.5", "J >= 0.6",
                      "median content words per title",
                      "outcome of the J >= 0.5 repeats: accepted / rejected / gate failure"], body), ""]
    L += ["Title length differs by system (column above): two 4-word titles reach J = 0.6 with 3 shared words, "
          "two 14-word titles need about 11, so part of the higher GPT-5.5 and Luna rates is a length effect. "
          "The matched pairs below show what a match looks like.", ""]
    L += ["Examples of matched pairs at J >= 0.5 (earlier -> later):", ""]
    ex = sorted(rep[0.5], key=lambda x: -x["jaccard"])
    seen_sys = collections.Counter()
    for x in ex:
        if seen_sys[x["system"]] >= 2:
            continue
        seen_sys[x["system"]] += 1
        L.append(f"- {x['system']} rep{x['rep']} (J={x['jaccard']}): \"{x['earlier_title']}\" ({x['earlier_class']}) "
                 f"-> {x['rounds_apart']} rounds later \"{x['later_title']}\" ({x['later_class']})")
    L += ["", "Representative lessons:", ""]
    for q in quotes:
        L.append(f"- {q['system']} rep{q['rep']} ({q['outcome']}, {q['delta_pct']:+.1f}%): \"{q['short']}\"")
    if problems:
        L += ["", "Consistency problems:", ""] + [f"- {x}" for x in problems]
    c.write_outputs("a4_lessons", data, "\n".join(L))


if __name__ == "__main__":
    main()
