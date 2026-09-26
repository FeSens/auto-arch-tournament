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
from datetime import date
from pathlib import Path
from typing import Optional

from tools.site.run_notes import (
    leader_sample_caveat,
    render_run_note,
    render_single_rep_caveat,
)


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
SITE_VERSION = "v1 · 2026-09"

# Models registered for the next field but not yet fully represented in
# bench/results.jsonl. The status table is rendered on the leaderboard and
# models pages until all expected reps land; partial runs show their progress.
# Keep the result names in sync with tools/bench/models-gpt56-preview.yaml.
SCHEDULED_MODELS = (
    {
        "name": "gpt-6-astra_max",
        "label": "GPT-6 Astra max",
        "runtime_model": "codex:gpt-6-astra",
        "effort": "max",
        "expected_reps": 3,
    },
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

# Public model availability dates used by the release-date × score chart.
# Reasoning-effort variants share their underlying model family's date.
# Sources:
# - OpenAI API/Codex changelogs: GPT-5.4 (Mar 5), GPT-5.4 mini (Mar 17),
#   GPT-5.5 (Apr 23), and the GPT-5.6 launch week ending Jul 10.
# - Gemini API changelog: Gemini 3.1 Pro Preview (Feb 19) and Gemini 3.5
#   Flash GA (May 19).
# - Kimi K2.6 official tech-blog announcement (Apr 20).
MODEL_RELEASES = {
    # First documented Codex support: https://learn.chatgpt.com/docs/changelog
    # 2026-09-03, Codex CLI 0.153.1.
    "gpt-6-astra_max":{"date": "2026-09-03", "label": "GPT-6 Astra max", "provider": "openai"},
    # First documented Codex support: https://learn.chatgpt.com/docs/changelog
    # 2026-09-22, Codex CLI 0.156.0 ("Choose GPT-6 Sol or GPT-6 Luna").
    "gpt-6-sol_xhigh":{"date": "2026-09-22", "label": "GPT-6 Sol xhigh", "provider": "openai"},
    # Public release 2026-09-22 (operator); first Claude Code support in the
    # 2.1.280 changelog ("Added Claude Opus 5.5 (`claude-opus-5-5`)").
    "claude-opus-5_5_xhigh":{"date": "2026-09-22", "label": "Claude Opus 5.5 xhigh", "provider": "anthropic"},
    "gemini-3_1-pro":  {"date": "2026-02-19", "label": "Gemini 3.1 Pro",  "provider": "google"},
    "gpt-5_4_xhigh":  {"date": "2026-03-05", "label": "GPT-5.4 xhigh",   "provider": "openai"},
    "gpt-5_4-mini":   {"date": "2026-03-17", "label": "GPT-5.4 mini",    "provider": "openai"},
    "kimi-k2_6":      {"date": "2026-04-20", "label": "Kimi K2.6",       "provider": "kimi"},
    "gpt-5_5_medium": {"date": "2026-04-23", "label": "GPT-5.5 medium",  "provider": "openai"},
    "gpt-5_5_high":   {"date": "2026-04-23", "label": "GPT-5.5 high",    "provider": "openai"},
    "gpt-5_5_xhigh":  {"date": "2026-04-23", "label": "GPT-5.5 xhigh",   "provider": "openai"},
    "gemini-3_5-flash":{"date": "2026-05-19", "label": "Gemini 3.5 Flash", "provider": "google"},
    "gpt-5_6-luna":   {"date": "2026-07-10", "label": "GPT-5.6 Luna",    "provider": "openai"},
    "gpt-5_6-terra":  {"date": "2026-07-10", "label": "GPT-5.6 Terra",   "provider": "openai"},
    "gpt-5_6-sol":    {"date": "2026-07-10", "label": "GPT-5.6 Sol",     "provider": "openai"},
}

PROVIDER_COLORS = {
    "openai": "var(--c2)",
    "google": "var(--c1)",
    "kimi": "var(--c3)",
    "anthropic": "#D97757",  # Anthropic orange
}

# Control/ablation arms have no public "release date" (they are not LLMs, or
# not being scored as one), so they are excluded from the release-date x
# fitness chart's coverage requirement. Mirrors the informal convention
# already used in tools/bench/report.py's render_comparison_section (model
# name equals "static" or starts with "static-"); extended here to cover the
# E1b random-mutation control and E1c naive-* prompt-ablation arms.
CONTROL_MODELS = {"static", "random-mutation"}


def is_control_model(name: str) -> bool:
    """True for control/ablation arms (E1a static, E1b random-mutation, E1c
    naive-*) that are exempt from the release-chart's MODEL_RELEASES coverage
    assertion."""
    return name in CONTROL_MODELS or name.startswith("naive-") or name.startswith("static-")

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


# Configurations kept in bench/results.jsonl but not shown on the site. The
# E1b random-mutation control never produces a valid design (every candidate
# fails formal), so it scores the baseline and reads as a model on the charts.
SITE_HIDDEN_MODELS = {"random-mutation"}


def load_reps(results_path: Path, repo: Path) -> list[Rep]:
    """Load rows from results.jsonl and enrich each with its winners list."""
    reps: list[Rep] = []
    for raw in results_path.read_text().splitlines():
        if not raw.strip():
            continue
        d = json.loads(raw)
        if d.get("model") in SITE_HIDDEN_MODELS:
            continue
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
    """Render registered models until their expected repetitions are present."""
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
        <td>{status} · {expected} planned rep{'s' if expected != 1 else ''}</td>
      </tr>""")
    if not rows:
        return ""

    return f"""
<section class="section" id="scheduled-field">
  <div class="eyebrow">Scheduled field</div>
  <h2>Registered benchmark runs</h2>
  <p class="prose">
    Each configuration uses the reasoning effort and repetition count shown below.
    Results move into the
    leaderboard and per-model detail automatically as each rep completes.
  </p>
  <div class="wide">
  <table class="bench">
    <caption>Reasoning effort and planned repetitions per model</caption>
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

<div id="chart-tip" role="tooltip" hidden></div>
<style>
  #chart-tip { position: fixed; z-index: 50; pointer-events: none; max-width: 320px;
    padding: 6px 9px; border-radius: 4px; background: var(--ink, #262a33); color: var(--bg, #faf9f7);
    font: 12px/1.35 Inter, ui-sans-serif, system-ui, sans-serif; box-shadow: 0 2px 8px rgba(0,0,0,.18); }
  svg [data-tip] { cursor: default; }
</style>
<script>
(() => {
  // Chart tooltips: any SVG element with data-tip shows it on hover or tap.
  const tip = document.getElementById("chart-tip");
  const place = (e) => {
    const pad = 14, w = tip.offsetWidth, h = tip.offsetHeight;
    let x = e.clientX + pad, y = e.clientY + pad;
    if (x + w > innerWidth - 8) x = e.clientX - w - pad;
    if (y + h > innerHeight - 8) y = e.clientY - h - pad;
    tip.style.left = x + "px"; tip.style.top = y + "px";
  };
  document.addEventListener("pointerover", (e) => {
    const t = e.target.closest && e.target.closest("[data-tip]");
    if (!t) return;
    tip.textContent = t.getAttribute("data-tip"); tip.hidden = false; place(e);
  });
  document.addEventListener("pointermove", (e) => { if (!tip.hidden) place(e); });
  document.addEventListener("pointerout", (e) => {
    const t = e.target.closest && e.target.closest("[data-tip]");
    if (t && !(e.relatedTarget && t.contains(e.relatedTarget))) tip.hidden = true;
  });
})();
</script>

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


def _axis_titles(ml, mt, plot_w, plot_h, xtitle, ytitle):
    """Axis titles: x centred under the tick labels, y rotated along the axis."""
    cy = mt + plot_h / 2
    return [
        f'  <text class="axis-label" x="{ml + plot_w / 2:.1f}" y="{mt + plot_h + 42:.1f}" '
        f'text-anchor="middle">{xtitle}</text>',
        f'  <text class="axis-label" x="{ml - 50:.1f}" y="{cy:.1f}" text-anchor="middle" '
        f'transform="rotate(-90 {ml - 50:.1f} {cy:.1f})">{ytitle}</text>',
    ]


HUMAN_HINT = "above: beats the human baseline"

PROVIDER_NAMES = {"openai": "OpenAI", "google": "Google", "kimi": "Moonshot (Kimi)",
                  "anthropic": "Anthropic"}


def _display_name(model: str) -> str:
    """Short human name for chart labels (MODEL_RELEASES label if known)."""
    meta = MODEL_RELEASES.get(model)
    return meta["label"] if meta else model


def _provider_color(model: str, fallback: str) -> str:
    meta = MODEL_RELEASES.get(model)
    return PROVIDER_COLORS.get(meta["provider"], fallback) if meta else fallback


def _legend(x0, y0, providers, extras=()):
    """One-row legend: provider swatches, then extra (label, svg-marker) pairs."""
    out, cx = [], x0
    for prov in providers:
        name = PROVIDER_NAMES.get(prov, prov)
        out.append(f'  <circle cx="{cx + 5:.1f}" cy="{y0 - 4:.1f}" r="5" fill="{PROVIDER_COLORS[prov]}"/>')
        out.append(f'  <text class="legend" x="{cx + 15:.1f}" y="{y0:.1f}">{name}</text>')
        cx += 15 + len(name) * 6.2 + 18
    for name, marker in extras:
        out.append(marker.format(cx=cx + 5, cy=y0 - 4, x0=cx - 2, x1=cx + 11))
        out.append(f'  <text class="legend" x="{cx + 15:.1f}" y="{y0:.1f}">{name}</text>')
        cx += 15 + len(name) * 6.2 + 18
    return out


CHART_STYLE = """  <style>
    text { font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    .axis-line { stroke: var(--rule, #d8d4cf); stroke-width: 1; }
    .grid { stroke: var(--rule, #d8d4cf); stroke-width: .6; }
    .axis-label { font-size: 12px; fill: var(--ink, #262a33); }
    .tick { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 10px; fill: var(--ink-muted, #77716c); }
    .legend { font-size: 11.5px; fill: var(--ink-muted, #77716c); }
    .name { font-size: 12px; font-weight: 600; paint-order: stroke;
            stroke: var(--bg, #faf9f7); stroke-width: 4px; stroke-linejoin: round; }
    .note { font-size: 10.5px; letter-spacing: .06em; text-transform: uppercase; }
    .pt { stroke: var(--bg, #faf9f7); stroke-width: 2; }
    .baseline { stroke: var(--ink-muted, #77716c); stroke-width: 1; stroke-dasharray: 4 3; }
    g.dot:hover .pt { stroke: var(--ink, #262a33); }
  </style>"""


def _human_line(ml, plot_w, hy, bbox_out=None):
    """Red dashed VexRiscv fitness line with an 'above human baseline' hint
    at its right end. Appends the hint's text box to bbox_out if given."""
    txt = f"Human reference (VexRiscv {VEXRISCV_REF['fitness']:.0f})"
    if bbox_out is not None:
        bbox_out.append((ml + plot_w - 6 - len(txt) * 6.1, hy - 16, ml + plot_w - 2, hy + 2))
    return [
        f'  <line stroke="var(--c-human)" stroke-width="1.2" stroke-dasharray="5 4" '
        f'x1="{ml}" y1="{hy:.1f}" x2="{ml + plot_w}" y2="{hy:.1f}"/>',
        f'  <text class="tick" x="{ml + plot_w - 6:.1f}" y="{hy - 6:.1f}" text-anchor="end" '
        f'paint-order="stroke" stroke="var(--bg, #faf9f7)" stroke-width="6" stroke-linejoin="round" '
        f'style="fill: var(--c-human)">{txt}</text>',
    ]


def _spread_1d(items, lo, hi, gap):
    """Give each item a label_y near its py, at least `gap` apart and
    inside [lo, hi]: push down top-to-bottom, then, if the stack overflows,
    push back up from the bottom."""
    s = sorted(items, key=lambda it: it["py"])
    prev = lo - gap
    for it in s:
        it["label_y"] = max(it["py"] + 4, prev + gap)
        prev = it["label_y"]
    nxt = hi + gap
    for it in reversed(s):
        it["label_y"] = min(it["label_y"], nxt - gap)
        nxt = it["label_y"]
    return items


def _place_labels_2d(items, bounds, step=13, max_shift=156, obstacles=()):
    """Place two-line labels (name + sub) next to their points without
    overlapping each other, any point, or leaving `bounds`.

    Each item needs px, py (point), label and sub (strings), and optionally
    prefer ("start" = right of the point, "end" = left). Candidates are tried
    nearest-first: vertical shifts 0, -step, +step, ... on the preferred side,
    then the other side. Sets lbl_x, anchor, label_y (baseline of the name
    line) and pushed (label moved off the point's row, so draw a leader).
    obstacles: extra (x0, y0, x1, y1) boxes labels must avoid (other text).
    """
    x0, y0, x1, y1 = bounds

    def box(it, anchor, ly):
        cw = it.get("char_w", 6.7)
        w = max(len(it["label"]) * cw, len(it.get("sub", "")) * 6.1) + 2
        lx = it["px"] + 11 if anchor == "start" else it["px"] - 11
        bx0 = lx if anchor == "start" else lx - w
        bottom = ly + 15 if it.get("sub") else ly + 4
        return lx, (bx0, ly - 11, bx0 + w, bottom)

    def hits(a, b, tol=1.0):
        return (a[0] < b[2] - tol and b[0] < a[2] - tol
                and a[1] < b[3] - tol and b[1] < a[3] - tol)

    dots = [(it["px"] - 8, it["py"] - 8, it["px"] + 8, it["py"] + 8) for it in items]
    placed = list(obstacles)
    shifts = [0]
    for k in range(1, max_shift // step + 1):
        shifts += [-k * step, k * step]
    # Crowded, high-scoring points first; ties top-down.
    for it in sorted(items, key=lambda it: (it["py"], it["px"])):
        sides = [it.get("prefer", "start")]
        sides.append("end" if sides[0] == "start" else "start")
        best = None
        for dy in shifts:
            for anchor in sides:
                ly = it["py"] + 3 + dy
                lx, b = box(it, anchor, ly)
                if b[0] < x0 or b[2] > x1 or b[1] < y0 or b[3] > y1:
                    continue
                own = (it["px"] - 8, it["py"] - 8, it["px"] + 8, it["py"] + 8)
                if any(hits(b, p) for p in placed) or any(
                        hits(b, d) for d in dots if d != own):
                    continue
                best = (lx, anchor, ly, b)
                break
            if best:
                break
        if best is None:  # no free slot: keep it on the point's row
            lx, b = box(it, sides[0], it["py"] + 3)
            best = (lx, sides[0], it["py"] + 3, b)
        it["lbl_x"], it["anchor"], it["label_y"], b = best
        it["pushed"] = abs(it["label_y"] - (it["py"] + 3)) > 1.5
        placed.append(b)
    return items


def chart_score_vs_lut4(aggs: list[ModelAgg], baseline_lut: int = 9563,
                         baseline_fit: float = BASELINE_FITNESS) -> str:
    """Scatter: fitness (Y) x LUT4 area (X), one point per model's best run,
    coloured by provider. Numbers live in hover tooltips; the shaded region
    is better than the human reference and smaller than the V0 baseline."""
    items = []
    for i, a in enumerate(aggs):
        if not a.best_rep or not a.best_rep.best_lut4 or not a.fitness_best:
            continue
        if is_control_model(a.model):
            continue  # controls score the baseline design
        items.append({"lut": a.best_rep.best_lut4, "fit": a.fitness_best,
                      "label": _display_name(a.model), "model": a.model,
                      "color": _provider_color(a.model, CHART_PALETTE[i % len(CHART_PALETTE)])})
    if not items:
        return ""
    hum = {"lut": VEXRISCV_REF["lut4"], "fit": VEXRISCV_REF["fitness"]}

    luts = [p["lut"] for p in items] + [baseline_lut, hum["lut"]]
    fits = [p["fit"] for p in items] + [baseline_fit, hum["fit"]]
    xmin, xmax = 0, max(luts) * 1.08
    ymin = min(250, min(fits) * 0.9)
    ymax = max(fits) * 1.06

    W, H = 900, 560
    ml, mr, mt, mb = 80, 30, 58, 64
    plot_w, plot_h = W - ml - mr, H - mt - mb

    def x(v): return ml + _scale(v, xmin, xmax, 0, plot_w)
    def y(v): return mt + _scale(v, ymax, ymin, 0, plot_h)

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-label="Fitness versus LUT4 by model">',
             CHART_STYLE]

    # Shaded region: beats the human reference on both axes, i.e. smaller
    # than VexRiscv AND higher fitness than VexRiscv.
    qx, qy = x(hum["lut"]), y(hum["fit"])
    parts.append(f'  <rect x="{ml}" y="{mt}" width="{qx - ml:.1f}" height="{qy - mt:.1f}" '
                 f'fill="var(--c2)" opacity="0.08"/>')
    quad_lines = ["Smaller and", "faster than", "VexRiscv"]
    for k, line in enumerate(quad_lines):
        parts.append(f'  <text class="note" x="{ml + 8}" y="{mt + 16 + 13 * k}" style="fill: var(--c2)">{line}</text>')
    quad_box = (ml, mt, ml + 8 + max(len(l) for l in quad_lines) * 7.0, mt + 20 + 13 * len(quad_lines))

    for t in _nice_ticks(ymin, ymax, 7):
        py = y(t)
        parts.append(f'  <line class="grid" x1="{ml}" y1="{py:.1f}" x2="{ml+plot_w}" y2="{py:.1f}"/>')
        parts.append(f'  <text class="tick" x="{ml-10}" y="{py+4:.1f}" text-anchor="end">{t:.0f}</text>')
    for t in _nice_ticks(xmin, xmax, 8):
        px = x(t)
        label = (f"{t/1000:g}k" if t >= 1000 else f"{t:.0f}")
        parts.append(f'  <text class="tick" x="{px:.1f}" y="{mt+plot_h+18}" text-anchor="middle">{label}</text>')
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt+plot_h}" x2="{ml+plot_w}" y2="{mt+plot_h}"/>')
    parts += _axis_titles(ml, mt, plot_w, plot_h, "Area · LUT4 count (← smaller is better)",
                          "Fitness · CoreMark iter/s (↑ better)")

    # Human reference lines: fitness (horizontal) and area (vertical).
    parts.append(f'  <line stroke="var(--c-human)" stroke-width="1.2" stroke-dasharray="5 4" '
                 f'x1="{ml}" y1="{qy:.1f}" x2="{ml+plot_w}" y2="{qy:.1f}"/>')
    parts.append(f'  <line stroke="var(--c-human)" stroke-width="1.2" stroke-dasharray="5 4" '
                 f'x1="{qx:.1f}" y1="{mt}" x2="{qx:.1f}" y2="{mt+plot_h}"/>')
    hint = f"Human reference (VexRiscv {hum['fit']:.0f})"
    hint_box = (ml + plot_w - 6 - len(hint) * 5.9, qy - 16, ml + plot_w, qy - 2)
    parts.append(f'  <text class="tick" x="{ml+plot_w-6:.1f}" y="{qy-6:.1f}" text-anchor="end" '
                 f'style="fill: var(--c-human)">{hint}</text>')

    # Legend.
    provs = [p for p in PROVIDER_COLORS if any(
        MODEL_RELEASES.get(it["model"], {}).get("provider") == p for it in items)]
    parts += _legend(ml, 22, provs, extras=[
        ("VexRiscv (human)", '  <rect x="{cx:.1f}" y="{cy:.1f}" width="9" height="9" '
                             'transform="rotate(45 {cx:.1f} {cy:.1f}) translate(-4.5 -4.5)" fill="var(--c-human)"/>'),
        ("V0 baseline", '  <circle cx="{cx:.1f}" cy="{cy:.1f}" r="4.5" fill="var(--bg)" '
                        'stroke="var(--ink-muted)" stroke-width="1.5"/>')])

    # Reference points.
    hx, hy = x(hum["lut"]), qy
    bx, by = x(baseline_lut), y(baseline_fit)
    refs = [
        {"px": hx, "py": hy, "label": "VexRiscv (human)", "color": "var(--c-human)", "char_w": 7.2},
        {"px": bx, "py": by, "label": "V0 baseline", "color": "var(--ink-muted)", "char_w": 7.2},
    ]
    for it in items:
        it["px"], it["py"], it["char_w"] = x(it["lut"]), y(it["fit"]), 7.2
    everything = items + refs
    # The human line itself is an obstacle, so no name sits on it.
    line_box = (ml, qy - 1.5, ml + plot_w, qy + 1.5)
    vline_box = (qx - 1.5, mt, qx + 1.5, mt + plot_h)
    _place_labels_2d(everything, (ml + 2, mt + 4, W - 6, mt + plot_h - 2),
                     obstacles=[hint_box, line_box, vline_box, quad_box])

    for it in everything:
        if it["pushed"]:
            parts.append(
                f'  <line x1="{it["px"]:.1f}" y1="{it["py"]:.1f}" '
                f'x2="{it["lbl_x"] + (-3 if it["anchor"] == "start" else 3):.1f}" '
                f'y2="{it["label_y"] - 4:.1f}" stroke="{it["color"]}" stroke-width="1" opacity="0.4"/>')
    parts.append(f'  <g data-tip="VexRiscv (human reference) · fitness {hum["fit"]:.0f} · {hum["lut"]:,} LUT4">'
                 f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="12" fill="transparent"/>'
                 f'<rect x="{hx-4.5:.1f}" y="{hy-4.5:.1f}" width="9" height="9" '
                 f'transform="rotate(45 {hx:.1f} {hy:.1f})" fill="var(--c-human)"/></g>')
    parts.append(f'  <g data-tip="V0 baseline · fitness {baseline_fit:.0f} · {baseline_lut:,} LUT4">'
                 f'<circle cx="{bx:.1f}" cy="{by:.1f}" r="12" fill="transparent"/>'
                 f'<circle cx="{bx:.1f}" cy="{by:.1f}" r="4.5" fill="var(--bg)" stroke="var(--ink-muted)" '
                 f'stroke-width="1.5"/></g>')
    for it in items:
        parts.append(
            f'  <g class="dot" data-tip="{it["label"]} · fitness {it["fit"]:.0f} · {it["lut"]:,} LUT4">'
            f'<circle cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="12" fill="transparent"/>'
            f'<circle class="pt" cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="6.5" fill="{it["color"]}"/></g>')
    for it in everything:
        parts.append(
            f'  <text class="name" x="{it["lbl_x"]:.1f}" y="{it["label_y"]:.1f}" '
            f'text-anchor="{it["anchor"]}" style="fill: {it["color"]}">{it["label"]}</text>')

    parts.append('</svg>')
    return "\n".join(parts)


def chart_release_vs_fitness(aggs: list[ModelAgg]) -> str:
    """METR-inspired scatter: public release date × peak HWE fitness."""
    items = []
    for a in aggs:
        if is_control_model(a.model):
            continue
        release = MODEL_RELEASES.get(a.model)
        if not release or a.fitness_best is None:
            continue
        released = date.fromisoformat(release["date"])
        items.append({
            "model": a.model,
            "label": release["label"],
            "provider": release["provider"],
            "released": released,
            "day": released.toordinal(),
            "fit": float(a.fitness_best),
            "color": PROVIDER_COLORS[release["provider"]],
        })
    if not items:
        return ""

    earliest = min(it["released"] for it in items)
    latest = max(it["released"] for it in items)
    xmin = date(earliest.year, earliest.month, 1).toordinal()
    if latest.month == 12:
        xmax = date(latest.year + 1, 1, 1).toordinal()
    else:
        xmax = date(latest.year, latest.month + 1, 1).toordinal()
    ymin = min(BASELINE_FITNESS * 0.96, min(it["fit"] for it in items) * 0.94)
    ymax = max(it["fit"] for it in items) * 1.07

    W, H = 920, 580
    ml, mr, mt, mb = 90, 40, 58, 64
    plot_w, plot_h = W - ml - mr, H - mt - mb

    def x(v): return ml + _scale(v, xmin, xmax, 0, plot_w)
    def y(v): return mt + _scale(v, ymax, ymin, 0, plot_h)

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-label="Peak HWE fitness by model release date">',
             CHART_STYLE]
    provs = [p for p in PROVIDER_COLORS if any(it["provider"] == p for it in items)]
    parts += _legend(ml, 22, provs, extras=[
        ("OLS trend", '  <line x1="{x0:.1f}" y1="{cy:.1f}" x2="{x1:.1f}" y2="{cy:.1f}" '
                      'stroke="var(--c2)" stroke-width="2" stroke-dasharray="5 3" opacity="0.6"/>')])

    # Monthly grid, using the first day of each month within the chart window.
    start = date.fromordinal(xmin)
    end = date.fromordinal(xmax)
    year, month = start.year, start.month
    first_month_label = True
    while True:
        tick = date(year, month, 1)
        if tick > end:
            break
        if tick >= start:
            px = x(tick.toordinal())
            label = tick.strftime("%b %Y") if first_month_label or tick.month == 1 else tick.strftime("%b")
            parts.append(f'  <text class="tick" x="{px:.1f}" y="{mt+plot_h+20}" text-anchor="middle">{label}</text>')
            first_month_label = False
        if month == 12:
            year += 1; month = 1
        else:
            month += 1

    for t in _nice_ticks(ymin, ymax, 8):
        py = y(t)
        parts.append(f'  <line class="grid" x1="{ml}" y1="{py:.1f}" x2="{ml+plot_w}" y2="{py:.1f}"/>')
        parts.append(f'  <text class="tick" x="{ml-10}" y="{py+4:.1f}" text-anchor="end">{t:.0f}</text>')

    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt+plot_h}" x2="{ml+plot_w}" y2="{mt+plot_h}"/>')

    by = y(BASELINE_FITNESS)
    parts.append(f'  <line class="baseline" x1="{ml}" y1="{by:.1f}" x2="{ml+plot_w}" y2="{by:.1f}"/>')
    parts.append(f'  <text class="tick" x="{ml+8}" y="{by-7:.1f}">V0 baseline · {BASELINE_FITNESS:.0f}</text>')

    # Ordinary least-squares trend. This is descriptive, not a forecast.
    if len(items) >= 2:
        xs = [it["day"] for it in items]
        ys = [it["fit"] for it in items]
        xmean, ymean = statistics.fmean(xs), statistics.fmean(ys)
        denom = sum((v - xmean) ** 2 for v in xs)
        if denom:
            slope = sum((vx - xmean) * (vy - ymean) for vx, vy in zip(xs, ys)) / denom
            intercept = ymean - slope * xmean
            y1, y2 = slope * xmin + intercept, slope * xmax + intercept
            parts.append(
                f'  <line x1="{x(xmin):.1f}" y1="{y(y1):.1f}" '
                f'x2="{x(xmax):.1f}" y2="{y(y2):.1f}" '
                'stroke="var(--c2)" stroke-width="2" stroke-dasharray="7 6" opacity="0.55"/>'
            )

    parts += _axis_titles(ml, mt, plot_w, plot_h, "Public model release date",
                          "Peak HWE fitness (↑ better)")
    human_boxes = []
    if ymin <= VEXRISCV_REF["fitness"] <= ymax:
        parts += _human_line(ml, plot_w, y(VEXRISCV_REF["fitness"]), human_boxes)

    for it in items:
        it["px"], it["py"] = x(it["day"]), y(it["fit"])
        it["char_w"] = 7.2
        it["prefer"] = "start" if it["px"] < ml + plot_w * 0.72 else "end"
    base_box = (ml + 4, by - 17, ml + 140, by + 2)
    _place_labels_2d(items, (ml + 2, mt + 4, W - 6, mt + plot_h - 2),
                     obstacles=[*human_boxes, base_box])

    for it in items:
        if it["pushed"]:
            # Leader from the dot to the near edge of the label's name line.
            parts.append(
                f'  <line x1="{it["px"]:.1f}" y1="{it["py"]:.1f}" '
                f'x2="{it["lbl_x"] + (-3 if it["anchor"] == "start" else 3):.1f}" '
                f'y2="{it["label_y"] - 4:.1f}" '
                f'stroke="{it["color"]}" stroke-width="1" opacity="0.45"/>'
            )
    for it in items:
        parts.append(
            f'  <g class="dot" data-tip="{it["label"]} · peak fitness {it["fit"]:.0f} · '
            f'released {it["released"].strftime("%b %d, %Y")}">'
            f'<circle cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="12" fill="transparent"/>'
            f'<circle class="pt" cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" '
            f'r="6.5" fill="{it["color"]}"/></g>'
        )
    for it in items:
        parts.append(
            f'  <text class="name" x="{it["lbl_x"]:.1f}" y="{it["label_y"]:.1f}" '
            f'text-anchor="{it["anchor"]}" style="fill: {it["color"]}">{it["label"]}</text>'
        )

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
        if is_control_model(a.model):
            continue  # controls never leave the baseline line
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
        color = CHART_PALETTE[i % len(CHART_PALETTE)]
        if MODEL_RELEASES.get(a.model, {}).get("provider") == "anthropic":
            color = PROVIDER_COLORS["anthropic"]
        series.append((a.model, color, running))

    if not series:
        return ""

    all_fits = [pt[1] for s in series for pt in s[2]]
    ymin = min(all_fits) * 0.95
    ymax = max(all_fits) * 1.04

    W, H = 920, 480
    ml, mr, mt, mb = 90, 250, 24, 64
    plot_w, plot_h = W - ml - mr, H - mt - mb
    xmin, xmax = 0, n_rounds

    def x(v): return ml + _scale(v, xmin, xmax, 0, plot_w)
    def y(v): return mt + _scale(v, ymax, ymin, 0, plot_h)

    yticks = _nice_ticks(ymin, ymax, 8)

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-label="Best fitness over rounds, per model">',
             CHART_STYLE]

    # grid
    for t in yticks:
        py = y(t)
        parts.append(f'  <line class="grid" x1="{ml}" y1="{py:.1f}" x2="{ml+plot_w}" y2="{py:.1f}"/>')
        parts.append(f'  <text class="tick" x="{ml-8}" y="{py+4:.1f}" text-anchor="end">{t:.0f}</text>')
    for t in range(0, n_rounds + 1):
        px = x(t)
        if t % 5 == 0:
            parts.append(f'  <line class="grid" x1="{px:.1f}" y1="{mt}" x2="{px:.1f}" y2="{mt+plot_h}"/>')
        parts.append(f'  <text class="tick" x="{px:.1f}" y="{mt+plot_h+18}" text-anchor="middle">{t}</text>')

    # axes
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt+plot_h}" x2="{ml+plot_w}" y2="{mt+plot_h}"/>')
    parts.append(f'  <line class="axis-line" x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+plot_h}"/>')

    # baseline horizontal
    by = y(baseline_fit)
    parts.append(f'  <line class="baseline" x1="{ml}" y1="{by:.1f}" x2="{ml+plot_w}" y2="{by:.1f}"/>')
    parts.append(f'  <text class="label" x="{ml+plot_w-6:.1f}" y="{by-6:.1f}" text-anchor="end" paint-order="stroke" stroke="var(--bg, #faf9f7)" stroke-width="3.5" fill="var(--ink-muted)">baseline {baseline_fit:.0f}</text>')

    # VexRiscv human reference — horizontal red dashed line
    human_text = []
    if ymin <= VEXRISCV_REF["fitness"] <= ymax:
        line, text = _human_line(ml, plot_w, y(VEXRISCV_REF["fitness"]))
        parts.append(line)
        human_text.append(text)  # drawn after the step lines, on top

    # axis labels
    parts += _axis_titles(ml, mt, plot_w, plot_h,
                          "Round (3 hypothesis slots each)", "Best fitness so far")

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
        tip = f"{_display_name(model)} · best {pts[-1][1]:.0f}"
        parts.append(f'  <g data-tip="{tip}"><path d="{" ".join(path)}" stroke="transparent" '
                     f'stroke-width="10" fill="none"/>'
                     f'<path d="{" ".join(path)}" stroke="{color}" stroke-width="1.8" fill="none"/></g>')
    parts += human_text

    # Endpoint dots + one-line labels spread to fit the plot height.
    label_items = []
    for (model, color, pts) in series:
        final = pts[-1][1]
        reached = next(r for r, f in pts if f == final)
        rx, ry = x(pts[-1][0]), y(final)
        label_items.append({"model": model, "color": color, "px": rx,
                            "py": ry, "final": final, "reached": reached})
    _spread_1d(label_items, lo=mt + 4, hi=mt + plot_h - 2, gap=14)

    lbl_x = ml + plot_w + 26
    for it in label_items:
        # Elbow leader: dot -> right, then to the label row.
        parts.append(
            f'  <polyline points="{it["px"]:.1f},{it["py"]:.1f} '
            f'{it["px"] + 10:.1f},{it["py"]:.1f} {lbl_x - 4:.1f},{it["label_y"] - 4:.1f}" '
            f'fill="none" stroke="{it["color"]}" stroke-width="1" opacity="0.5"/>')
    for it in label_items:
        parts.append(f'  <circle cx="{it["px"]:.1f}" cy="{it["py"]:.1f}" r="4.5" fill="{it["color"]}" class="point"/>')
    for it in label_items:
        reached = "baseline" if it["reached"] == 0 else f'R{it["reached"]}'
        parts.append(
            f'  <text class="name" x="{lbl_x:.1f}" y="{it["label_y"]:.1f}" style="fill: {it["color"]}">'
            f'{_display_name(it["model"])} <tspan class="tick" style="font-weight: 400">'
            f'{it["final"]:.0f} · {reached}</tspan></text>')

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
    release_chart_svg = chart_release_vs_fitness(aggs)

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

<section class="section" id="release-curve">
  <div class="eyebrow">Capability over time</div>
  <h2>Model release date × peak HWE score</h2>
  <figure class="chart">
    {release_chart_svg}
    <figcaption>
      Each point is one model configuration's best completed HWE Bench rep;
      reasoning-effort variants share their underlying model family's public release date.
      The dashed fit is descriptive, not a forecast. Release dates come from the
      <a href="https://learn.chatgpt.com/docs/changelog" class="ext">OpenAI Codex notes</a>,
      <a href="https://ai.google.dev/gemini-api/docs/changelog" class="ext">Gemini API changelog</a>,
      <a href="https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md" class="ext">Claude Code changelog</a>,
      and <a href="https://www.kimi.com/blog/kimi-k2-6" class="ext">Kimi K2.6 announcement</a>.
    </figcaption>
  </figure>
</section>

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
    <caption>Best of recorded reps per model · {sum(a.n_total for a in aggs)} reps total · VexRiscv human reference in red · baseline V0 in italic</caption>
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
  {render_single_rep_caveat(aggs)}
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
    iter/s{leader_sample_caveat(leader)}, <strong>{stat_delta}</strong> over the V0 baseline core, and clear of the
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
    The standard field has three independent reps per model, including GPT-6 Astra
    at max reasoning effort. Recorded results are shown as each repetition finishes.
    Reps share no state. Each rep's final fitness
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

        configuration_note = ""
        if a.model == "gpt-6-astra_max":
            sample_note = (
                "One of three planned repetitions recorded; repeatability has not yet been measured."
                if a.n_total == 1 else f"{a.n_total} independent repetitions recorded."
            )
            configuration_note = (
                '<p class="prose">GPT-6 Astra via Codex · '
                'reasoning effort <span class="mono">max</span> · '
                f'15 rounds × 3 hypotheses per round. {sample_note}</p>'
            )
            completed = [r.final_fitness for r in a.reps
                         if r.is_complete and r.final_fitness is not None]
            if len(completed) > 1:
                configuration_note += (
                    '<p class="prose">Across completed repetitions: '
                    f'mean {statistics.mean(completed):.2f} ± '
                    f'{statistics.stdev(completed):.2f} sample SD.</p>'
                )
            configuration_note += (
                '<p class="prose">Repetitions 2 and 3 resumed after a usage-limit pause; '
                'reported wall time includes that pause. Valid attempts were preserved. '
                'The acceptance counts include the baseline; rep3 also has one FPGA '
                'placement failure outside the legacy broken counter. '
                'OAuth dollar billing was unavailable; raw cost zeros are parser defaults. '
                '<a href="https://github.com/FeSens/auto-arch-tournament/blob/main/'
                'bench/gpt-6-astra_max/README.md" class="ext">Run and recovery notes</a>.</p>'
            )

        configuration_note += render_run_note(a)

        sections.append(f"""
<section class="section" id="{a.model}">
  <div class="eyebrow">{a.model}</div>
  <h2>{a.model.replace('_', ' ').replace('-', ' ')}</h2>
{configuration_note}

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
