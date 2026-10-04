"""Shared loaders and helpers for the V2 descriptive analyses.

Reads only repo files (bench/v2, research/v2, research/runs). Standard library
only, like research/v2/scripts/analyze_main.py (the run host has no scipy).

Scope: the 36 scored runs, six systems x reps 1-6. The scored row of a run is
the last status=done row for that (model, rep) in bench/v2/results*.jsonl
(each scored (model, rep) has exactly one done row, so first and last agree
with analyze_main.py's "first complete run" rule). Opus rep1 and Luna rep1
have no held-out score in their results row (incident 08); their held-out
fields come from research/runs/EXP-2026-09-28-v2-main/incident_08/
holdout_rescored.jsonl, as in analyze_main.py.
"""
from __future__ import annotations

import glob
import json
import math
import random
import re
import statistics
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BENCH = REPO / "bench" / "v2"
EXP = REPO / "research" / "runs" / "EXP-2026-09-28-v2-main"
OUT = Path(__file__).resolve().parent / "results"

# Ordered by the paper's tiers: {Opus, Sonnet} > {Sol, Astra} > {GPT-5.5, Luna}.
SYSTEMS = [
    ("claude-opus-5_5_xhigh-v2", "Opus 5.5", "Claude Code"),
    ("claude-sonnet-5-5_xhigh-v2", "Sonnet 5.5", "Claude Code"),
    ("gpt-6_1-sol_xhigh-v2", "GPT-6.1 Sol", "Codex CLI"),
    ("gpt-6-astra_xhigh-v2", "GPT-6 Astra", "Codex CLI"),
    ("gpt-5_5_xhigh-v2", "GPT-5.5", "Codex CLI"),
    ("gpt-6-luna_xhigh-v2", "GPT-6 Luna", "Codex CLI"),
]
MODELS = [m for m, _, _ in SYSTEMS]
NAME = {m: n for m, n, _ in SYSTEMS}
CLI = {m: c for m, _, c in SYSTEMS}
REPS = range(1, 7)

# analysis_final.json uses these short names in "ranking".
FINAL_SHORT = {"claude-opus-5_5_xhigh-v2": "Opus", "gpt-6_1-sol_xhigh-v2": "Sol 6.1",
               "gpt-6-luna_xhigh-v2": "Luna", "gpt-6-astra_xhigh-v2": "Astra",
               "claude-sonnet-5-5_xhigh-v2": "Sonnet 5.5", "gpt-5_5_xhigh-v2": "GPT-5.5"}

ACCEPT_MARGIN_PCT = (math.exp(0.045) - 1.0) * 100.0  # 4.60%, tools/accept_rule.py


# ---- loaders ----------------------------------------------------------------

def _read_jsonl(path: Path) -> list[dict]:
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def load_scored_rows() -> dict[tuple[str, int], dict]:
    """(model, rep) -> scored results row, held-out fields filled for rep1s."""
    done: dict[tuple[str, int], dict] = {}
    for f in sorted(glob.glob(str(BENCH / "results*.jsonl"))):
        for row in _read_jsonl(Path(f)):
            key = (row.get("model"), row.get("rep"))
            if key[0] in MODELS and key[1] in REPS and row.get("status") == "done":
                prev = done.get(key)
                if prev is None or (row.get("ended_at") or "") >= (prev.get("ended_at") or ""):
                    done[key] = dict(row)
    rescored = {(r["model"], r["rep"]): r
                for r in _read_jsonl(EXP / "incident_08" / "holdout_rescored.jsonl")}
    for key, row in done.items():
        if row.get("holdout_geomean_iter_s") is None and key in rescored:
            rs = rescored[key]
            for k in ("holdout_geomean_iter_s", "holdout_kernels", "holdout_fmax_mhz",
                      "loop_fmax_mhz", "holdout_fmax_pairs"):
                row[k] = rs.get(k)
            row["_holdout_source"] = "incident_08 rescored"
        else:
            row["_holdout_source"] = "runner"
    missing = [(m, r) for m in MODELS for r in REPS if (m, r) not in done]
    if missing:
        raise SystemExit(f"missing scored rows: {missing}")
    return done


def cross_check_final(rows: dict) -> list[str]:
    """Compare per-system geomean held-out with analysis_final.json and the
    per-run values in analysis_final.md. Returns a list of problems (empty = ok)."""
    problems = []
    final = json.loads((EXP / "analysis_final.json").read_text())
    ranking = {r["system"]: r for r in final["ranking"]}
    for m in MODELS:
        vals = [rows[(m, r)]["holdout_geomean_iter_s"] for r in REPS]
        gm = geomean(vals)
        ref = ranking[FINAL_SHORT[m]]["geomean"]
        if abs(gm - ref) > 0.05:
            problems.append(f"{NAME[m]}: geomean {gm:.2f} vs analysis_final {ref:.2f}")
    # per-run table in analysis_final.md ("| Opus | 1 | done | 7769.6 | ... | yes |")
    md = (EXP / "analysis_final.md").read_text().splitlines()
    inv = {v: k for k, v in FINAL_SHORT.items()}
    for line in md:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 6 and cells[0] in inv and cells[5] == "yes":
            m, rep = inv[cells[0]], int(cells[1])
            mine = rows[(m, rep)]["holdout_geomean_iter_s"]
            if abs(mine - float(cells[3])) > 0.06:
                problems.append(f"{NAME[m]} rep{rep}: {mine:.1f} vs analysis_final.md {cells[3]}")
    return problems


def run_dir(model: str, rep: int) -> Path:
    return BENCH / model / f"rep{rep}"


def load_log(model: str, rep: int) -> list[dict]:
    return _read_jsonl(run_dir(model, rep) / "log.jsonl")


def candidates(model: str, rep: int) -> list[dict]:
    """log.jsonl rows minus the round-0 baseline retest (45 per run)."""
    return [d for d in load_log(model, rep) if d.get("round_id", 0) != 0]


# ---- outcome classes ----------------------------------------------------------

def broken_class(error: str | None) -> str:
    """Error string -> stage class, in the gate order of tools/tournament.py:run_slot."""
    e = (error or "").strip()
    head = e.split(":", 1)[0]
    if head == "formal_failed":
        rest = e.split(":", 1)[1].strip() if ":" in e else ""
        if rest.startswith("timeout"):
            return "formal_timeout"
        if rest.startswith("ch0_contract"):
            return "formal_ch0_precheck"
        return "formal_check_failed"
    return head or "unknown"


def outcome_class(d: dict) -> str:
    """Fine outcome class of one candidate row."""
    o = d.get("outcome")
    if o == "improvement":
        return "accepted"
    if o == "regression":
        dp = d.get("delta_pct")
        if dp is not None and dp > ACCEPT_MARGIN_PCT:
            return "rejected_lost_to_sibling"
        if dp is not None and dp > 0:
            return "rejected_below_margin"
        return "rejected_no_gain"
    if o == "placement_failed":
        return "placement_failed"
    if o == "broken":
        return broken_class(d.get("error"))
    return f"other:{o}"


# Gate order (the stage that stopped the candidate).
STAGE_OF = {
    "hypothesis_gen_failed": "1 hypothesis agent",
    "schema_error": "1 hypothesis agent",
    "implementation_compile_failed": "2 implementation (lint)",
    "sandbox_violation": "3 sandbox check",
    "build_failed": "4 build",
    "formal_ch0_precheck": "5 formal",
    "formal_check_failed": "5 formal",
    "formal_timeout": "5 formal",
    "cosim_failed": "6 cosim",
    "placement_failed": "7 FPGA place and route",
    "coremark_failed": "8 FPGA CoreMark",
    "fpga_report_unparsed": "8 FPGA CoreMark",
}


# ---- statistics -----------------------------------------------------------------

def geomean(xs):
    xs = list(xs)
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def ranks(xs):
    """Average ranks (1-based), ties share the mean rank."""
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    r = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2.0 + 1.0
        i = j + 1
    return r


def pearson(x, y):
    mx, my = statistics.fmean(x), statistics.fmean(y)
    sxy = sum((a - mx) * (b - my) for a, b in zip(x, y))
    sxx = sum((a - mx) ** 2 for a in x)
    syy = sum((b - my) ** 2 for b in y)
    if sxx == 0 or syy == 0:
        return float("nan")
    return sxy / math.sqrt(sxx * syy)


def spearman(x, y, perms: int = 20000, seed: int = 20261004):
    """Spearman rho and a two-sided permutation p-value (exact for n <= 8)."""
    rx, ry = ranks(x), ranks(y)
    rho = pearson(rx, ry)
    if math.isnan(rho):
        return {"rho": None, "p": None, "n": len(x)}
    n = len(x)
    hits = total = 0
    if n <= 8:
        import itertools
        for p in itertools.permutations(ry):
            total += 1
            if abs(pearson(rx, list(p))) >= abs(rho) - 1e-12:
                hits += 1
    else:
        rng = random.Random(seed)
        yy = list(ry)
        for _ in range(perms):
            rng.shuffle(yy)
            total += 1
            if abs(pearson(rx, yy)) >= abs(rho) - 1e-12:
                hits += 1
    return {"rho": rho, "p": hits / total, "n": n}


def stratified_spearman(groups):
    """Spearman over within-group ranks: groups = list of (xs, ys) per system.
    Removes between-system level differences (a system that is both costly and
    strong no longer drives the correlation)."""
    rx, ry = [], []
    for xs, ys in groups:
        rx += ranks(xs)
        ry += ranks(ys)
    return spearman(rx, ry)


def fmt_rho(s) -> str:
    """'+0.83 (p=0.012)'; a permutation p of 0 is shown as p<0.0001."""
    if s is None or s.get("rho") is None:
        return ""
    pv = "p<0.0001" if s["p"] == 0 else f"p={s['p']:.3f}"
    return f"{s['rho']:+.2f} ({pv})"


def median_range(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs), min(xs), max(xs)


# ---- output -----------------------------------------------------------------------

def md_table(headers, rows) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join("" if c is None else str(c) for c in r) + " |")
    return "\n".join(out)


def fmt(x, nd=2):
    if x is None:
        return ""
    if isinstance(x, float) and math.isnan(x):
        return ""
    if isinstance(x, int):
        return f"{x:,}"
    return f"{x:,.{nd}f}"


def pct(a, b, nd=1):
    return f"{100.0 * a / b:.{nd}f}%" if b else ""


def write_outputs(stem: str, data: dict, markdown: str) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{stem}.json").write_text(json.dumps(data, indent=1, sort_keys=False, default=str) + "\n")
    (OUT / f"{stem}.md").write_text(markdown.rstrip() + "\n")
    print(f"wrote {OUT / (stem + '.json')} and .md")


# Token-like strings (API keys, bearer tokens, long base64) for scrubbing any
# command text that is written to an output file.
_SECRET = re.compile(r"(sk-[A-Za-z0-9_-]{8,}|Bearer\s+\S+|[A-Za-z0-9+/=_-]{40,}|"
                     r"(?i:token|secret|password|api[_-]?key)\s*[=:]\s*\S+)")


def scrub(text: str) -> str:
    return _SECRET.sub("[redacted]", text)
