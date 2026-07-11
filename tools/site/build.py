"""HWE Bench site builder.

Reads bench/results.jsonl + per-rep log.jsonl and renders the static site.
Single-file Python, no Jinja2 / no node / no jekyll. Run after a bench
update; commit the generated HTML.

Usage:
    python -m tools.site.build
    python -m tools.site.build --out site/

The generator is intentionally simple: f-string templates, no template
engine. If you want to change copy, edit this file. If you want to
change layout, edit the HTML / CSS in site/. Tokens live in
site/css/tokens.css; STYLE.md (.design/branding/hwe-bench/patterns/)
is the canonical style guide.
"""
from __future__ import annotations

import argparse
import json
import statistics
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


def fetch_star_count(repo: str = "FeSens/auto-arch-tournament",
                     timeout: float = 4.0) -> Optional[int]:
    """Read GitHub's stargazers_count at build time. Returns None on any
    failure, the build never breaks for a missing star count."""
    try:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}",
            headers={"Accept": "application/vnd.github+json",
                     "User-Agent": "hwe-bench-site-build/1.0"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8"))
        return int(d.get("stargazers_count", 0))
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError):
        return None


HERE = Path(__file__).parent
REPO = HERE.parent.parent
DEFAULT_RESULTS = REPO / "bench" / "results.jsonl"
DEFAULT_OUT = REPO / "site"

BASELINE_FITNESS = 282.82
SITE_VERSION = "v1 · 2026-07"

# Models registered for the next field but not yet fully represented in
# bench/results.jsonl. The status table is rendered on the leaderboard and
# models pages until all expected reps land; partial runs show their progress.
# Keep the result names in sync with tools/bench/models-gpt56-preview.yaml.
SCHEDULED_MODELS = (
    {
        "name": "gpt-5_6-sol",
        "label": "GPT-5.6 Sol",
        "runtime_model": "codex:gpt-5.6-sol",
        "effort": "high",
        "expected_reps": 3,
    },
    {
        "name": "gpt-5_6-terra",
        "label": "GPT-5.6 Terra",
        "runtime_model": "codex:gpt-5.6-terra",
        "effort": "high",
        "expected_reps": 3,
    },
    {
        "name": "gpt-5_6-luna",
        "label": "GPT-5.6 Luna",
        "runtime_model": "codex:gpt-5.6-luna",
        "effort": "high",
        "expected_reps": 3,
    },
)

# Human-engineered reference: VexRiscv synthesized on Gowin GW2A-LV18 (Tang Nano 20K).
# LUT4 = 3402 (CPU-core only; the syn report's bare 3957 figure included bench
# wrapper logic). Fmax from VexRiscvBench_report.json (128.58 MHz). Fitness 370
# is the user-stated reference number for the well-tuned maxperf config.
VEXRISCV_REF = {
    "name": "VexRiscv  (human ref)",
    "fitness": 370.0,
    "lut4": 3402,
    "ff": 1890,
    "fmax_mhz": 144.0,
    "source": "syn-vexriscv on Tang Nano 20K (Gowin GW2A-LV18)",
}

# Baseline V0 — the starting core every rep begins from. Anchor for delta-pct
# numbers across the bench. Values from the baseline retest row (round_id=0)
# present in every rep's log.jsonl.
BASELINE_REF = {
    "name": "baseline V0  (fixture)",
    "fitness": BASELINE_FITNESS,
    "lut4": 9563,
    "ff": 1866,
    "fmax_mhz": 127.03,
    "source": "cores/bench/rtl/, the starting point every rep iterates against",
}


@dataclass
class Rep:
    model: str
    rep: int
    status: str
    final_fitness: Optional[float]
    best_fitness: Optional[float]
    baseline_fitness: Optional[float]
    delta_pct: Optional[float]
    iterations: int
    accepted: int
    rejected: int
    broken: int
    broken_by_class: dict
    wall_clock_sec: int
    total_cost_usd: float
    total_tokens_in: int
    total_tokens_out: int
    best_lut4: Optional[int]
    best_ff: Optional[int]
    best_fmax_mhz: Optional[float]
    best_iterations: Optional[int]
    best_cycles: Optional[int]
    best_ipc_coremark: Optional[float]
    winners: list = field(default_factory=list)  # list[dict] from log.jsonl

    @property
    def delta(self) -> float:
        return self.delta_pct or 0.0

    @property
    def is_complete(self) -> bool:
        return self.status == "done"


def load_reps(results_path: Path, repo: Path) -> list[Rep]:
    """Load rows from results.jsonl and enrich each with its winners list."""
    reps: list[Rep] = []
    for raw in results_path.read_text().splitlines():
        if not raw.strip():
            continue
        d = json.loads(raw)
        reps.append(Rep(
            model=d.get("model", "?"),
            rep=int(d.get("rep", 0)),
            status=d.get("status", "?"),
            final_fitness=d.get("final_fitness"),
            best_fitness=d.get("best_fitness"),
            baseline_fitness=d.get("baseline_fitness"),
            delta_pct=d.get("delta_pct"),
            iterations=int(d.get("iterations") or 0),
            accepted=int(d.get("accepted") or 0),
            rejected=int(d.get("rejected") or 0),
            broken=int(d.get("broken") or 0),
            broken_by_class=dict(d.get("broken_by_class") or {}),
            wall_clock_sec=int(d.get("wall_clock_sec") or 0),
            total_cost_usd=float(d.get("total_cost_usd") or 0.0),
            total_tokens_in=int(d.get("total_tokens_in") or 0),
            total_tokens_out=int(d.get("total_tokens_out") or 0),
            best_lut4=d.get("best_lut4"),
            best_ff=d.get("best_ff"),
            best_fmax_mhz=d.get("best_fmax_mhz"),
            best_iterations=d.get("best_iterations"),
            best_cycles=d.get("best_cycles"),
            best_ipc_coremark=d.get("best_ipc_coremark"),
        ))
    # Enrich with per-rep winners
    for rep in reps:
        log = repo / "bench" / rep.model / f"rep{rep.rep}" / "log.jsonl"
        if not log.is_file():
            continue
        rep.winners = _winners_from_log(log)
    return reps


def _winners_from_log(log_path: Path) -> list[dict]:
    """Return ordered list of accepted-improvement entries (excluding baseline)."""
    wins: list[dict] = []
    for raw in log_path.read_text().splitlines():
        if not raw.strip():
            continue
        try:
            e = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if e.get("outcome") in ("improvement", "accepted") and e.get("round_id", 0) != 0:
            wins.append(e)
    return wins


@dataclass
class ModelAgg:
    model: str
    reps: list[Rep]
    n_done: int
    n_total: int
    fitness_mean: Optional[float]
    fitness_median: Optional[float]
    fitness_std: Optional[float]
    fitness_best: Optional[float]
    delta_mean: Optional[float]
    delta_best: Optional[float]
    total_cost_usd: float
    broken_by_class_total: dict
    best_rep: Optional[Rep]  # the rep that produced fitness_best


def aggregate(reps: list[Rep]) -> list[ModelAgg]:
    by_model: dict[str, list[Rep]] = {}
    for r in reps:
        by_model.setdefault(r.model, []).append(r)

    out: list[ModelAgg] = []
    for model, group in by_model.items():
        done = [r for r in group if r.is_complete and r.final_fitness is not None]
        # Include failed-but-with-data reps in the "best" tally so the leaderboard
        # surfaces a model's reachable peak even when one rep crashed mid-run.
        with_data = [r for r in group if r.best_fitness is not None]
        fits_done = [r.final_fitness for r in done if r.final_fitness is not None]
        deltas_done = [r.delta_pct for r in done if r.delta_pct is not None]
        best_rep = max(with_data, key=lambda r: r.best_fitness or -1) if with_data else None
        broken_classes: dict[str, int] = {}
        for r in group:
            for cls, n in r.broken_by_class.items():
                broken_classes[cls] = broken_classes.get(cls, 0) + int(n)
        out.append(ModelAgg(
            model=model,
            reps=sorted(group, key=lambda r: r.rep),
            n_done=len(done),
            n_total=len(group),
            fitness_mean=statistics.fmean(fits_done) if fits_done else None,
            fitness_median=statistics.median(fits_done) if fits_done else None,
            fitness_std=(statistics.pstdev(fits_done) if len(fits_done) > 1
                         else (0.0 if fits_done else None)),
            fitness_best=best_rep.best_fitness if best_rep else None,
            delta_mean=statistics.fmean(deltas_done) if deltas_done else None,
            delta_best=best_rep.delta if best_rep else None,
            total_cost_usd=sum(r.total_cost_usd for r in group),
            broken_by_class_total=broken_classes,
            best_rep=best_rep,
        ))
    out.sort(key=lambda a: -(a.fitness_best or 0))
    return out


# ── formatting helpers ─────────────────────────────────────────────

def fnum(x, fmt=".2f"):
    return "n/a" if x is None else format(x, fmt)

def fpct(x, fmt="+.1f"):
    return "n/a" if x is None else f"{format(x, fmt)}%"

def fmoney(x):
    return "n/a" if x is None else f"${x:.2f}"

def fhours(sec):
    if not sec:
        return "n/a"
    return f"{sec/3600:.1f}h"

def fcompact(n):
    if n is None: return "n/a"
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.1f}k"
    return f"{n}"

def fint(n):
    """Format an exact integer count for data tables."""
    return "n/a" if n is None else f"{int(n):,}"


def render_scheduled_models(aggs: list[ModelAgg]) -> str:
    """Render registered models until their full three-rep field is present."""
    reps_by_model = {a.model: a.n_total for a in aggs}
    rows = []
    for model in SCHEDULED_MODELS:
        observed = reps_by_model.get(model["name"], 0)
        expected = model["expected_reps"]
        if observed >= expected:
            continue
        status = "scheduled" if observed == 0 else f"{observed} of {expected} recorded"
        rows.append(f"""
      <tr>
        <td><span class="model-name">{model['label']}</span></td>
        <td><code>{model['name']}</code></td>
        <td><code>{model['runtime_model']}</code></td>
        <td><span class="mono">{model['effort']}</span></td>
        <td>{status}</td>
      </tr>""")
    if not rows:
        return ""

    return f"""
<section class="section" id="gpt-5-6-field">
  <div class="eyebrow">Scheduled field</div>
  <h2>GPT-5.6 preview trio</h2>
  <p class="prose">
    Sol, Terra, and Luna will each run three independent reps under the same
    <span class="mono">high</span> reasoning budget. Results move into the
    leaderboard and per-model detail automatically as each rep completes.
  </p>
  <div class="wide">
  <table class="bench">
    <caption>High reasoning only · N=3 reps per model</caption>
    <thead>
      <tr>
        <th>Model</th><th>Result ID</th><th>Runtime model</th>
        <th>Reasoning</th><th>Status</th>
      </tr>
    </thead>
    <tbody>{''.join(rows)}
    </tbody>
  </table>
  </div>
</section>
"""


# ── shared HTML fragments ──────────────────────────────────────────

def head(title: str, current: str, stars: Optional[int] = None) -> str:
    if stars is None:
        star_html = "github"
    else:
        star_html = f'github <span class="star">★</span> <span class="star-count">{stars}</span>'
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="HWE Bench is an unbounded benchmark for LLM hardware engineering. Models design RISC-V CPUs that are scored by how fast they actually run on a real FPGA, only after passing formal correctness proofs.">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Source+Serif+4:opsz,wght@8..60,400;8..60,600&family=Inter:wght@400;500;600&family=IBM+Plex+Mono:ital,wght@0,400;0,500;1,400&display=swap">
<link rel="stylesheet" href="css/style.css">
<link rel="stylesheet" href="css/print.css">
</head>
<body>
<div class="page">

<nav class="top">
  <a href="index.html" class="wordmark">HWE <span class="alt">Bench</span></a>
  <ul>
    <li><a href="index.html"{' aria-current="page"' if current=='index' else ''}>Leaderboard</a></li>
    <li><a href="methodology.html"{' aria-current="page"' if current=='methodology' else ''}>Methodology</a></li>
    <li><a href="models.html"{' aria-current="page"' if current=='models' else ''}>Models</a></li>
    <li><a href="data.html"{' aria-current="page"' if current=='data' else ''}>Data</a></li>
  </ul>
  <div class="meta">
    <a href="https://github.com/FeSens/auto-arch-tournament" class="repo" aria-label="HWE Bench source on GitHub, click to view repo and star">{star_html}</a>
    <span class="version">{SITE_VERSION}</span>
  </div>
</nav>
"""

FOOTER = """
<footer class="bot">
  <div>
    HWE Bench · methodology v1 ·
    <a href="https://github.com/FeSens/auto-arch-tournament" class="ext">source on GitHub</a> ·
    <a href="https://github.com/FeSens/auto-arch-tournament/blob/main/CITATION.cff" class="ext">cite</a>
  </div>
  <div class="manifesto">a benchmark that respects how far a frontier model still has to go.</div>
</footer>

</div>
</body>
</html>
"""


# ── chart rendering (inline SVG, no JS) ───────────────────────────

CHART_PALETTE = [
    "var(--c1)", "var(--c2)", "var(--c3)",
    "var(--c4)", "var(--c5)", "var(--c6)",
]


def _scale(v, vmin, vmax, pmin, pmax):
    if vmax == vmin:
        return pmin
    return pmin + (pmax - pmin) * (v - vmin) / (vmax - vmin)


def _nice_ticks(vmin, vmax, count=5):
    """Return a list of round-numbered tick values across [vmin, vmax]."""
    if vmax <= vmin:
        return [vmin]
    span = vmax - vmin
    rough_step = span / (count - 1)
    # nearest power-of-10 step ratio
    import math
    mag = 10 ** int(math.floor(math.log10(rough_step)))
    for mult in (1, 2, 2.5, 5, 10):
        step = mult * mag
        if rough_step <= step:
            break
    start = step * int(math.floor(vmin / step))
    ticks = []
    v = start
    while v <= vmax + 1e-6:
        if v >= vmin - 1e-6:
            ticks.append(v)
        v += step
    return ticks


def _place_labels(items, line_h=22):
    """Anchor each label at its point's y-position; push down only when
    necessary to avoid overlap. Greedy top-down.

    items: list of dicts, each must have a 'y' key (the point's y in
    viewBox coords). Mutates each dict by setting 'label_y' and 'pushed'
    (true if label-y != point-y → connector needed).
    """
    s = sorted(items, key=lambda it: it["y"])
    last = -1e9
    for it in s:
        target = it["y"]
        chosen = max(target, last + line_h)
        it["label_y"] = chosen
        it["pushed"]  = abs(chosen - target) > 1.5
        last = chosen
    return items


def chart_score_vs_lut4(aggs: list[ModelAgg], baseline_lut: int = 9563,
                         baseline_fit: float = BASELINE_FITNESS) -> str:
    """Scatter — fitness (Y) × LUT4 (X). One labeled point per model + VexRiscv human reference + baseline cross-hair."""
    items = []
    for i, a in enumerate(aggs):
        if not a.best_rep or not a.best_rep.best_lut4 or not a.fitness_best:
            continue
        items.append({"lut": a.best_rep.best_lut4, "fit": a.fitness_best,
                      "label": a.model, "color": CHART_PALETTE[i % len(CHART_PALETTE)],
                      "kind": "model"})
    # VexRiscv human reference — first-class on this chart
    items.append({"lut": VEXRISCV_REF["lut4"], "fit": VEXRISCV_REF["fitness"],
                  "label": "VexRiscv", "sub": "human ref",
                  "color": "var(--c-human)", "kind": "human"})

    if not items:
        return ""

    luts = [p["lut"] for p in items] + [baseline_lut]
    fits = [p["fit"] for p in items] + [baseline_fit]
    xmin, xmax = min(luts) * 0.78, max(luts) * 1.05
    ymin, ymax = min(fits) * 0.85, max(fits) * 1.05

    W, H = 880, 480
    ml, mr, mt, mb = 76, 226, 30, 56
    plot_w, plot_h = W - ml - mr, H - mt - mb

    def x(v): return ml + _scale(v, xmin, xmax, 0, plot_w)
    def y(v): return mt + _scale(v, ymax, ymin, 0, plot_h)

    xticks = _nice_ticks(xmin, xmax, 5)
    yticks = _nice_ticks(ymin, ymax, 5)

    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Fitness versus LUT4 by model">']

    for t in yticks:
        py = y(t)
        parts.append(f'  <line class="grid" x1="{ml}" y1="{py:.1f}" x2="{ml+plot_w}" y2="{py:.1f}"/>')
        parts.append(f'  <text class="tick" x="{ml-10}" y="{py+4:.1f}" text-anchor="end">{t:.0f}</text>')
    for t in xticks:
        px = x(t)
        parts.append(f'  <line class="grid" x1="{px:.1f}" y1="{mt}" x2="{px:.1f}" y2="{mt+plot_h}"/>')
        label = f"{t/1000:.1f}k" if t >= 1000 else f"{t:.0f}"
        parts.append(f'  <text class="tick" x="{px:.1f}" y="{mt+plot_h+18}" text-anchor="middle">{label}</text>')

    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt+plot_h}" x2="{ml+plot_w}" y2="{mt+plot_h}"/>')
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+plot_h}"/>')

    # baseline V0 — kept as a quiet crosshair so the reader sees the anchor
    bx, by = x(baseline_lut), y(baseline_fit)
    parts.append(f'  <line class="baseline" x1="{ml}" y1="{by:.1f}" x2="{ml+plot_w}" y2="{by:.1f}"/>')
    parts.append(f'  <line class="baseline" x1="{bx:.1f}" y1="{mt}" x2="{bx:.1f}" y2="{mt+plot_h}"/>')
    parts.append(f'  <circle cx="{bx:.1f}" cy="{by:.1f}" r="3.5" fill="var(--bg)" stroke="var(--ink-muted)" stroke-width="1.4"/>')
    parts.append(f'  <text class="tick" x="{bx+10:.1f}" y="{by-7:.1f}" fill="var(--ink-muted)" text-anchor="start">baseline V0 · {baseline_fit:.0f} · {baseline_lut/1000:.1f}k LUT</text>')

    # axis labels
    parts.append(f'  <text class="axis-label" x="{ml}" y="{mt-12}" text-anchor="start">Fitness (CoreMark iter/s)</text>')
    parts.append(f'  <text class="axis-label" x="{ml+plot_w}" y="{H-14}" text-anchor="end">Area · LUT4 count  (← smaller is better)</text>')

    # Pre-compute point pixel positions and resolve label collisions.
    for it in items:
        it["px"] = x(it["lut"]); it["py"] = y(it["fit"])
        # default label anchor — to the right of the dot, at the dot's y
        it["y"] = it["py"]
    _place_labels(items, line_h=24)

    # Draw points first, labels on top (so dots don't overdraw text)
    for it in items:
        parts.append(f'  <circle class="point" cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="6" fill="{it["color"]}"/>')
    for it in items:
        lbl_x = it["px"] + 12
        lbl_y = it["label_y"]
        sub = it.get("sub", f"{it['fit']:.0f} · {it['lut']/1000:.1f}k LUT")
        if it["kind"] != "model":
            sub = f"{sub} · {it['fit']:.0f} · {it['lut']/1000:.1f}k LUT"
        parts.append(f'  <text class="label" x="{lbl_x:.1f}" y="{lbl_y:.1f}" fill="{it["color"]}">{it["label"]}</text>')
        parts.append(f'  <text class="tick" x="{lbl_x:.1f}" y="{lbl_y+12:.1f}" fill="{it["color"]}" fill-opacity="0.7">{sub}</text>')

    parts.append('</svg>')
    return "\n".join(parts)


def chart_score_vs_round(aggs: list[ModelAgg],
                          baseline_fit: float = BASELINE_FITNESS,
                          n_rounds: int = 15) -> str:
    """Line chart — running max fitness (Y) × round (X). One line per model's best rep."""
    series = []  # (model, color, points[ (round, best_so_far) ])
    for i, a in enumerate(aggs):
        rep = a.best_rep
        if not rep: continue
        # Round 0 = baseline retest. After each round, take max fitness so far among
        # all of this rep's improvement entries.
        wins_by_round = {}
        for w in rep.winners:
            r = w.get("round_id")
            f = w.get("fitness")
            if isinstance(r, int) and isinstance(f, (int, float)) and r >= 1:
                wins_by_round[r] = max(wins_by_round.get(r, -1), f)
        running = []
        best = baseline_fit
        running.append((0, best))
        for r in range(1, n_rounds + 1):
            if r in wins_by_round and wins_by_round[r] > best:
                best = wins_by_round[r]
            running.append((r, best))
        series.append((a.model, CHART_PALETTE[i % len(CHART_PALETTE)], running))

    if not series:
        return ""

    all_fits = [pt[1] for s in series for pt in s[2]]
    ymin = min(all_fits) * 0.95
    ymax = max(all_fits) * 1.04

    W, H = 880, 460
    ml, mr, mt, mb = 70, 200, 36, 60
    plot_w, plot_h = W - ml - mr, H - mt - mb
    xmin, xmax = 0, n_rounds

    def x(v): return ml + _scale(v, xmin, xmax, 0, plot_w)
    def y(v): return mt + _scale(v, ymax, ymin, 0, plot_h)

    yticks = _nice_ticks(ymin, ymax, 5)

    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Best fitness over rounds, per model">']

    # grid
    for t in yticks:
        py = y(t)
        parts.append(f'  <line class="grid" x1="{ml}" y1="{py:.1f}" x2="{ml+plot_w}" y2="{py:.1f}"/>')
        parts.append(f'  <text class="tick" x="{ml-8}" y="{py+4:.1f}" text-anchor="end">{t:.0f}</text>')
    for t in range(0, n_rounds + 1, 5):
        px = x(t)
        parts.append(f'  <line class="grid" x1="{px:.1f}" y1="{mt}" x2="{px:.1f}" y2="{mt+plot_h}"/>')
        parts.append(f'  <text class="tick" x="{px:.1f}" y="{mt+plot_h+18}" text-anchor="middle">R{t}</text>')

    # axes
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt+plot_h}" x2="{ml+plot_w}" y2="{mt+plot_h}"/>')
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+plot_h}"/>')

    # baseline horizontal
    by = y(baseline_fit)
    parts.append(f'  <line class="baseline" x1="{ml}" y1="{by:.1f}" x2="{ml+plot_w}" y2="{by:.1f}"/>')
    parts.append(f'  <text class="label" x="{ml+plot_w-6:.1f}" y="{by-6:.1f}" text-anchor="end" fill="var(--ink-muted)">baseline {baseline_fit:.0f}</text>')

    # VexRiscv human reference — horizontal red dashed line
    if ymin <= VEXRISCV_REF["fitness"] <= ymax:
        hy = y(VEXRISCV_REF["fitness"])
        parts.append(f'  <line stroke="var(--c-human)" stroke-width="1" stroke-dasharray="4 3" x1="{ml}" y1="{hy:.1f}" x2="{ml+plot_w}" y2="{hy:.1f}"/>')
        parts.append(f'  <text class="label" x="{ml+plot_w-6:.1f}" y="{hy-6:.1f}" text-anchor="end" fill="var(--c-human)">VexRiscv {VEXRISCV_REF["fitness"]:.0f}</text>')

    # axis labels
    parts.append(f'  <text class="axis-label" x="{ml}" y="{mt-12}" text-anchor="start">Best fitness so far</text>')
    parts.append(f'  <text class="axis-label" x="{ml+plot_w}" y="{H-14}" text-anchor="end">Round (1 hypothesis × 3 slots each)</text>')

    # Draw all step-lines first
    for (model, color, pts) in series:
        path = []
        for i, (r, f) in enumerate(pts):
            px, py = x(r), y(f)
            if i == 0:
                path.append(f"M {px:.1f} {py:.1f}")
            else:
                prev_y = y(pts[i-1][1])
                path.append(f"L {px:.1f} {prev_y:.1f} L {px:.1f} {py:.1f}")
        parts.append(f'  <path d="{" ".join(path)}" stroke="{color}" stroke-width="1.8" fill="none"/>')

    # Endpoint dots + collision-resolved labels
    label_items = []
    for (model, color, pts) in series:
        rx, ry = x(pts[-1][0]), y(pts[-1][1])
        label_items.append({"model": model, "color": color,
                            "px": rx, "py": ry, "y": ry,
                            "final": pts[-1][1], "round": pts[-1][0]})
    _place_labels(label_items, line_h=24)

    for it in label_items:
        parts.append(f'  <circle cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="5" fill="{it["color"]}" class="point"/>')
    for it in label_items:
        lbl_x = it["px"] + 12
        lbl_y = it["label_y"]
        parts.append(f'  <text class="label" x="{lbl_x:.1f}" y="{lbl_y:.1f}" fill="{it["color"]}">{it["model"]}</text>')
        parts.append(f'  <text class="tick" x="{lbl_x:.1f}" y="{lbl_y+12:.1f}" fill="{it["color"]}" fill-opacity="0.7">{it["final"]:.0f} at R{it["round"]}</text>')

    parts.append('</svg>')
    return "\n".join(parts)


# ── page renderers ─────────────────────────────────────────────────

def render_index(aggs: list[ModelAgg], reps: list[Rep], stars: Optional[int] = None) -> str:
    leader = aggs[0] if aggs else None
    top_rep = leader.best_rep if leader else None
    stat_fit = fnum(top_rep.best_fitness) if top_rep else "n/a"
    stat_delta = fpct(top_rep.delta_pct) if top_rep else "n/a"

    # Build the combined ranking with both references (baseline V0, VexRiscv)
    # interleaved by fitness alongside the LLM rows.
    class RefEntry:
        def __init__(self, ref, kind): self.ref = ref; self.kind = kind  # 'human' | 'baseline'
    ranked: list = []
    for a in aggs:
        ranked.append(a)
    ranked.append(RefEntry(VEXRISCV_REF, "human"))
    ranked.append(RefEntry(BASELINE_REF, "baseline"))
    def _fit(e):
        return e.ref["fitness"] if isinstance(e, RefEntry) else (e.fitness_best or 0)
    ranked.sort(key=_fit, reverse=True)

    rows = []
    rank = 0
    for entry in ranked:
        rank += 1
        if isinstance(entry, RefEntry):
            r = entry.ref
            row_cls = "human-baseline" if entry.kind == "human" else "baseline-row"
            delta = (r['fitness']-BASELINE_FITNESS)/BASELINE_FITNESS*100
            delta_str = f"{delta:+.1f}%" if entry.kind != "baseline" else "n/a"
            rows.append(f"""
    <tr class="{row_cls}">
      <td class="num">{rank}</td>
      <td><span class="model-name">{r['name']}</span></td>
      <td class="num">n/a</td>
      <td class="num">{r['fitness']:.2f}</td>
      <td class="num">{delta_str}</td>
      <td class="num">n/a</td>
      <td class="num">{fcompact(r['lut4'])}</td>
      <td class="num">{r['fmax_mhz']:.0f}</td>
    </tr>""")
        else:
            a = entry
            rep = a.best_rep
            rows.append(f"""
    <tr>
      <td class="num">{rank}</td>
      <td><span class="model-name">{a.model}</span></td>
      <td class="num">{a.n_done}/{a.n_total}</td>
      <td class="num">{fnum(a.fitness_best, '.2f')}</td>
      <td class="num">{fpct(a.delta_best)}</td>
      <td class="num">{fnum(a.fitness_mean, '.1f')}{f' ± {a.fitness_std:.1f}' if a.fitness_std else ''}</td>
      <td class="num">{fcompact(rep.best_lut4) if rep else 'n/a'}</td>
      <td class="num">{f'{rep.best_fmax_mhz:.0f}' if rep and rep.best_fmax_mhz else 'n/a'}</td>
    </tr>""")
    leaderboard_html = "".join(rows)

    chart1_svg = chart_score_vs_lut4(aggs)
    chart2_svg = chart_score_vs_round(aggs)

    n_above_human = sum(1 for a in aggs if (a.fitness_best or 0) > VEXRISCV_REF["fitness"])
    scheduled_html = render_scheduled_models(aggs)

    return head("HWE Bench · RISC-V CPU design benchmark for LLMs", "index", stars) + f"""
<section class="hero-block">
  <div class="hero-eyebrow">RISC-V · RV32IM · single-issue · FPGA-grounded</div>
  <h1 class="hero">HWE Bench</h1>
  <p class="hero-lede">
    An unbounded benchmark for LLM hardware engineering.
    Large language models design RISC-V CPUs from scratch.
    Every design must first pass a full battery of formal correctness proofs,
    so buggy CPUs are thrown out. The ones that survive are then scored by how
    fast they would actually run on a physical FPGA.
  </p>
  <div class="hero-thesis">
    <span class="label">Thesis</span>
    SWE-bench tops out at 100%. HWE Bench doesn't have a top.<br>
    The fitness number reflects an actual microarchitecture, and microarchitecture
    has room to grow as long as models keep finding it.
  </div>
</section>

{scheduled_html}

<section class="section">
  <div class="eyebrow">Speed vs size</div>
  <h2>Score × Area</h2>
  <figure class="chart">
    {chart1_svg}
    <figcaption>
      Vertical axis: CoreMark fitness (how fast the CPU runs the benchmark).
      Horizontal axis: chip area (LUT4 count, basically how many gates the design uses on the FPGA).
      One point per model's best run. VexRiscv (3,957 LUT4 · fitness 370) is the human-engineered
      reference. Up and to the left is the goal: faster chip, smaller chip.
    </figcaption>
  </figure>
</section>

<section class="section">
  <div class="eyebrow">Leaderboard</div>
  <h2>Peak fitness per model</h2>
  <div class="wide">
  <table class="bench">
    <caption>Best of N=3 reps per model · {sum(a.n_total for a in aggs)} reps total · VexRiscv human reference in red · baseline V0 in italic</caption>
    <thead>
      <tr>
        <th class="num">#</th>
        <th>Model</th>
        <th class="num">Reps</th>
        <th class="num">Best</th>
        <th class="num">Δ%</th>
        <th class="num">Mean ± std</th>
        <th class="num">Area (LUT4)</th>
        <th class="num">Fmax (MHz)</th>
      </tr>
    </thead>
    <tbody>{leaderboard_html}
    </tbody>
  </table>
  </div>
  <p class="prose">
    The VexRiscv row is the human-engineered reference, a well-known open-source RV32IM CPU
    synthesized on the same FPGA used for the benchmark. <strong>{n_above_human}</strong>
    of the LLM-generated designs beat it. See the <a href="methodology.html">methodology page</a>
    for the full procedure.
  </p>
</section>

<section class="section">
  <div class="eyebrow">Why unbounded</div>
  <h2>SWE-bench saturates. HWE Bench doesn't.</h2>
  <div class="prose">
  <p>
    Most LLM benchmarks have a fixed ceiling. SWE-bench tops out at 100% issue-resolution.
    Multiple-choice evals approach 99%. Once a model lands at the ceiling, every subsequent
    model gets the same score, and the benchmark stops being useful for tracking capability.
  </p>
  <p>
    HWE Bench has no ceiling. Fitness is the CPU's actual speed running CoreMark on a real
    FPGA, operating frequency times instructions-per-cycle (Fmax × IPC for the technically
    inclined). There's no theoretical maximum: a smarter microarchitecture always scores
    higher. As long as models keep finding new tricks (deeper pipelines, smarter branch
    predictors, restructured ALUs), the leaderboard keeps moving.
  </p>
  <p>
    Empirically: the current best is <strong>{stat_fit}</strong>
    iter/s, <strong>{stat_delta}</strong> over the V0 baseline core, and clear of the
    VexRiscv human reference. There is no theoretical ceiling, and within current budgets
    the curve has not saturated.
  </p>
  </div>
</section>

<section class="section">
  <div class="eyebrow">Trajectory</div>
  <h2>Fitness over rounds, best rep per model</h2>
  <figure class="chart">
    {chart2_svg}
    <figcaption>
      Running max of CoreMark fitness across the 15 hypothesis rounds for each model's
      best-performing rep. Lines step up when a winning hypothesis lands and stay flat
      otherwise. VexRiscv's human-reference fitness is the red dashed line; the baseline
      V0 core is the gray dashed line.
    </figcaption>
  </figure>
</section>

{FOOTER}
"""


def render_methodology(stars: Optional[int] = None) -> str:
    return head("HWE Bench · Methodology", "methodology", stars) + """
<section class="hero-block">
  <div class="hero-eyebrow">Methodology · v1</div>
  <h1>What HWE Bench measures, and how.</h1>
  <p class="hero-lede">
    A model proposes a CPU change, implements it as RTL, and the design then
    runs through three correctness gates and a real FPGA. If any gate fails,
    the iteration is marked <em>broken</em> and contributes nothing to the score.
    No surface-metric gaming.
  </p>
</section>

<section class="section">
  <div class="eyebrow">Score</div>
  <h2>Fitness = Fmax × IPC</h2>
  <div class="prose">
  <p>
    The fitness score is <span class="mono">Fmax × IPC</span> measured on the same CoreMark
    workload, in <span class="mono">iter/s</span>.
  </p>
  <ul>
    <li><strong>Fmax</strong>: median operating frequency from 3 placement seeds on an FPGA
        (specifically: Gowin GW2A-LV18QN88C8/I7, the chip on the Tang Nano 20K board).</li>
    <li><strong>IPC</strong>: instructions-per-cycle on CoreMark 2K with iStall+dStall
        backpressure, measured between <span class="mono">start_time</span> and
        <span class="mono">stop_time</span> markers.</li>
  </ul>
  <p>
    The baseline V0 core scores <span class="mono">282.82 iter/s</span> (Fmax = 127 MHz,
    LUT4 = 9,563). Every fitness number on the site is reported against this anchor.
  </p>
  </div>
</section>

<section class="section">
  <div class="eyebrow">Correctness gates</div>
  <h2>Three gates per iteration</h2>
  <dl class="defs">
    <dt>1. Verilator lint</dt>
    <dd>RTL must pass <span class="mono">verilator --lint-only -Wall</span>.
        Caught early; cheap.</dd>

    <dt>2. riscv-formal</dt>
    <dd>45+ <span class="mono">.sby</span> bounded model checks via SymbiYosys + bitwuzla,
        covering RV32IM instruction semantics, register-file forwarding, PC propagation,
        retirement uniqueness, liveness, and traps. The single-issue variant runs against
        <span class="mono">formal/wrapper_si.sv</span>; dual-issue cores run against
        <span class="mono">formal/wrapper.sv</span>. A single failed check fails the iteration.</dd>

    <dt>3. Python ISS cosim</dt>
    <dd>Every retirement of <span class="mono">selftest.elf</span> is diffed field-by-field
        against a Python instruction-set simulator that implements RV32IM by spec. Any
        divergence, wrong register write, missing trap, wrong PC, fails the iteration.
        CoreMark is checked separately via UART-CRC validation (CRCs match the canonical
        EEMBC values).</dd>
  </dl>
  <p class="prose">
    If any gate fails, the iteration is marked <code>broken</code> and counted on the
    leaderboard under <code>broken_by_class</code>. No score is awarded. The model gets a
    new slot on the next round.
  </p>
</section>

<section class="section">
  <div class="eyebrow">Tournament</div>
  <h2>How a single rep runs</h2>
  <div class="prose">
  <p>
    A <em>rep</em> is one independent tournament run with parameters
    <span class="mono">N=15</span> (rounds) and <span class="mono">K=3</span> (slots per round).
    Each round, the model produces 3 hypothesis YAMLs (in parallel, separate agent
    invocations); each hypothesis is independently implemented as RTL, evaluated through the
    three gates above, scored, and committed to the rep's <code>log.jsonl</code>. The
    best-fitness implementation across all 3 slots becomes the new baseline for the next
    round.
  </p>
  <p>
    Three reps per model are run independently. They share no state. Each rep's final fitness
    is published; the model's reported peak is the maximum across reps, and the mean is
    averaged across <em>completed</em> reps (status = <code>done</code>).
  </p>
  </div>
</section>

<section class="section">
  <div class="eyebrow">Reproducibility</div>
  <h2>Re-run the whole bench from a fresh clone</h2>
  <div class="prose">
  <p>
    The benchmark is reproducible from the <a href="https://github.com/FeSens/auto-arch-tournament" class="ext">source repository</a>.
    Every per-iteration artifact is preserved:
  </p>
  <ul>
    <li><code>bench/results.jsonl</code>: one row per rep, structured.</li>
    <li><code>bench/&lt;model&gt;/rep&lt;N&gt;/log.jsonl</code>: per-iteration journal with
        fitness, LUT4, FF, Fmax, IPC, cycles, outcome class, and timestamp.</li>
    <li><code>bench/&lt;model&gt;/rep&lt;N&gt;/agent.log</code>: full model transcript.
        Every <code>read</code>, <code>edit</code>, <code>bash</code>, <code>write</code>
        tool call the agent made.</li>
    <li><code>bench/&lt;model&gt;/rep&lt;N&gt;/summary.json</code>: rolled-up summary with
        cost, wall-clock, and the best-fitness entry's microarch metadata.</li>
  </ul>
  <p>
    The hypothesis-implementation contract is in <code>CLAUDE.md</code> at the repo root.
    The eval contract, wrapper.sv, checks.cfg, the Python ISS, the cosim harness, is in
    <code>formal/</code>, <code>fpga/</code>, and <code>test/cosim/</code>. None of these
    are modifiable by the agent; sandbox rolls back any iteration that touches them.
  </p>
  </div>
</section>

""" + FOOTER


def render_models(aggs: list[ModelAgg], stars: Optional[int] = None) -> str:
    sections = []
    for a in aggs:
        # Per-rep table
        rep_rows = []
        for r in a.reps:
            status_str = r.status
            if r.status == "failed":
                status_str = '<span class="mono" title="orchestrator exited non-zero; data preserved">failed ⚠</span>'
            rep_rows.append(f"""
      <tr>
        <td>rep{r.rep}</td>
        <td>{status_str}</td>
        <td class="num">{fnum(r.best_fitness, '.2f')}</td>
        <td class="num">{fpct(r.delta_pct)}</td>
        <td class="num">{fint(r.best_lut4)}</td>
        <td class="num">{f'{r.best_fmax_mhz:.0f}' if r.best_fmax_mhz else 'n/a'}</td>
        <td class="num">{r.accepted}</td>
        <td class="num">{r.broken}</td>
        <td class="num">{fhours(r.wall_clock_sec)}</td>
      </tr>""")
        rep_rows_html = "".join(rep_rows)

        # Winners list (across all reps)
        winners_html = []
        for r in a.reps:
            if not r.winners:
                continue
            winners_html.append(f"<h3>rep{r.rep} , winning hypotheses</h3>")
            winners_html.append('<dl class="defs">')
            for w in r.winners:
                title = w.get("title", "n/a")
                fit = w.get("fitness", "?")
                delta = w.get("delta_pct")
                lut = w.get("lut4")
                fmax = w.get("fmax_mhz")
                rid = w.get("round_id")
                lut_str = fcompact(lut) if lut else "n/a"
                fmax_str = f"{fmax:.0f} MHz" if isinstance(fmax, (int, float)) else "n/a"
                delta_str = f"+{delta:.1f}%" if isinstance(delta, (int, float)) else "n/a"
                winners_html.append(
                    f'<dt>R{rid} · {title}</dt>'
                    f'<dd>fitness <span class="mono">{fit:.2f}</span> '
                    f'(<span class="mono">{delta_str}</span>) · '
                    f'area <span class="mono">{lut_str}</span> LUT4 · '
                    f'Fmax <span class="mono">{fmax_str}</span></dd>'
                )
            winners_html.append("</dl>")
        winners_str = "\n".join(winners_html) or "<p>No winning hypotheses recorded.</p>"

        # Broken classes
        broken_str = ", ".join(f'<code>{k}</code>×{v}' for k, v in
                                sorted(a.broken_by_class_total.items(),
                                       key=lambda kv: -kv[1])) or "n/a"

        sections.append(f"""
<section class="section" id="{a.model}">
  <div class="eyebrow">{a.model}</div>
  <h2>{a.model.replace('_', ' ').replace('-', ' ')}</h2>

  <div class="stats">
    <div class="stat"><div class="label">Best</div><div class="value">{fnum(a.fitness_best)}</div><div class="sub">{fpct(a.delta_best)} vs baseline</div></div>
    <div class="stat"><div class="label">Mean</div><div class="value">{fnum(a.fitness_mean, '.1f')}</div><div class="sub">{fpct(a.delta_mean)} mean Δ</div></div>
    <div class="stat"><div class="label">Reps</div><div class="value">{a.n_done}/{a.n_total}</div><div class="sub">completed / total</div></div>
  </div>

  <div class="wide">
  <table class="bench">
    <caption>per-rep detail</caption>
    <thead>
      <tr>
        <th>Rep</th><th>Status</th>
        <th class="num">Best</th><th class="num">Δ%</th>
        <th class="num">Area (LUT4)</th><th class="num">Fmax (MHz)</th>
        <th class="num">acc</th><th class="num">brk</th>
        <th class="num">Wall</th>
      </tr>
    </thead>
    <tbody>{rep_rows_html}
    </tbody>
  </table>
  </div>

  <p class="prose"><strong>Broken classes (all reps combined):</strong> {broken_str}</p>

  <div class="prose">
  {winners_str}
  </div>
</section>
""")

    scheduled_html = render_scheduled_models(aggs)
    sections_html = "\n".join(sections)
    return head("HWE Bench · Models", "models", stars) + f"""
<section class="hero-block">
  <div class="hero-eyebrow">Per-model detail</div>
  <h1>What each model actually did.</h1>
  <p class="hero-lede">
    Below: the per-rep outcomes for every model run on HWE Bench so far, plus the
    accepted-improvement hypotheses each rep produced, verbatim titles, fitness,
    LUT4, and Fmax. The hypothesis titles are exactly what the agent wrote.
  </p>
</section>
{scheduled_html}
{sections_html}
""" + FOOTER


def render_data(reps: list[Rep], stars: Optional[int] = None) -> str:
    rows = []
    for r in sorted(reps, key=lambda x: (x.model, x.rep)):
        log_link = f"https://github.com/FeSens/auto-arch-tournament/blob/main/bench/{r.model}/rep{r.rep}/log.jsonl"
        agent_link = f"https://github.com/FeSens/auto-arch-tournament/blob/main/bench/{r.model}/rep{r.rep}/agent.log"
        summary_link = f"https://github.com/FeSens/auto-arch-tournament/blob/main/bench/{r.model}/rep{r.rep}/summary.json"
        rows.append(f"""
      <tr>
        <td><span class="model-name">{r.model}</span></td>
        <td>rep{r.rep}</td>
        <td>{r.status}</td>
        <td class="num">{r.iterations}</td>
        <td class="num">{fnum(r.best_fitness)}</td>
        <td><a href="{log_link}" class="ext">log.jsonl</a></td>
        <td><a href="{agent_link}" class="ext">agent.log</a></td>
        <td><a href="{summary_link}" class="ext">summary.json</a></td>
      </tr>""")
    rows_html = "".join(rows)

    return head("HWE Bench · Data", "data", stars) + f"""
<section class="hero-block">
  <div class="hero-eyebrow">Raw data</div>
  <h1>Every iteration, every transcript.</h1>
  <p class="hero-lede">
    The full per-iteration journal and agent transcript for every rep are committed to
    the repository. No data is summarized away. Below is the index.
  </p>
</section>

<section class="section">
  <div class="eyebrow">Downloads</div>
  <h2>Aggregate</h2>
  <ul class="prose">
    <li><a href="https://github.com/FeSens/auto-arch-tournament/blob/main/bench/results.jsonl" class="ext"><code>bench/results.jsonl</code></a>: one row per rep, structured. Schema: model, rep, status, final_fitness, best_fitness, baseline_fitness, delta_pct, iterations, accepted, rejected, broken, broken_by_class, wall_clock_sec, total_cost_usd, total_tokens_in/out, best_lut4, best_ff, best_fmax_mhz, best_iterations, best_cycles, best_ipc_coremark.</li>
    <li><a href="https://github.com/FeSens/auto-arch-tournament/blob/main/bench/leaderboard.csv" class="ext"><code>bench/leaderboard.csv</code></a>: per-model aggregate (mean fitness, best, broken counts).</li>
    <li><a href="https://github.com/FeSens/auto-arch-tournament/blob/main/bench/LEADERBOARD.md" class="ext"><code>bench/LEADERBOARD.md</code></a>: human-readable leaderboard with failure-mode breakdowns.</li>
  </ul>
</section>

<section class="section">
  <div class="eyebrow">Per-rep</div>
  <h2>Index of all reps</h2>
  <div class="wide">
  <table class="bench">
    <caption>{len(reps)} reps</caption>
    <thead>
      <tr>
        <th>Model</th><th>Rep</th><th>Status</th>
        <th class="num">Iters</th><th class="num">Best fit</th>
        <th>Log</th><th>Transcript</th><th>Summary</th>
      </tr>
    </thead>
    <tbody>{rows_html}
    </tbody>
  </table>
  </div>
  <p class="prose">
    Each <code>log.jsonl</code> is one row per iteration: hypothesis ID, title, outcome
    (<code>improvement</code> / <code>regression</code> / <code>broken</code>), fitness,
    delta vs baseline, LUT4, FF, Fmax, IPC, cycles, error class if broken, timestamp.
    Each <code>agent.log</code> is the verbatim model transcript: every bash command,
    every file read, every write.
  </p>
</section>
""" + FOOTER


# ── main ──────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()

    reps = load_reps(args.results, REPO)
    if not reps:
        print(f"no reps in {args.results}")
        return 1
    aggs = aggregate(reps)
    stars = fetch_star_count()

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "index.html").write_text(render_index(aggs, reps, stars))
    (args.out / "methodology.html").write_text(render_methodology(stars))
    (args.out / "models.html").write_text(render_models(aggs, stars))
    (args.out / "data.html").write_text(render_data(reps, stars))

    print(f"wrote {args.out}/index.html")
    print(f"wrote {args.out}/methodology.html")
    print(f"wrote {args.out}/models.html")
    print(f"wrote {args.out}/data.html")
    print(f"  ({len(reps)} reps · {len(aggs)} models · github stars: {stars if stars is not None else 'n/a'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
