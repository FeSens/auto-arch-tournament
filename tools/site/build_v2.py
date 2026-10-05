"""Render site/v2.html, the V2 results page, from the V2 analysis files.

The page is static output: the GitHub Pages workflow on `main` runs
build.py (which leaves v2.html alone), and the data this generator reads
lives on the `v2` branch. Regenerate there and copy the page to main:

    python -m tools.site.build_v2 [--out site]
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

from tools.site.build import FOOTER, head

REPO = Path(__file__).resolve().parents[2]
RUN = REPO / "research/runs/EXP-2026-09-28-v2-main"
GH = "https://github.com/FeSens/auto-arch-tournament"
GH_V2 = f"{GH}/tree/v2"
GH_V2_BLOB = f"{GH}/blob/v2"

# Analysis short name -> (results model, display name, CLI, color).
SYSTEMS = {
    "Opus": ("claude-opus-5_5_xhigh-v2", "Opus 5.5", "Claude Code", "var(--c1)"),
    "Sonnet 5.5": ("claude-sonnet-5-5_xhigh-v2", "Sonnet 5.5", "Claude Code", "var(--c4)"),
    "Sol 6.1": ("gpt-6_1-sol_xhigh-v2", "GPT-6.1 Sol", "Codex CLI", "var(--c2)"),
    "Astra": ("gpt-6-astra_xhigh-v2", "GPT-6 Astra", "Codex CLI", "var(--c3)"),
    "GPT-5.5": ("gpt-5_5_xhigh-v2", "GPT-5.5", "Codex CLI", "var(--c5)"),
    "Luna": ("gpt-6-luna_xhigh-v2", "GPT-6 Luna", "Codex CLI", "var(--c6)"),
}
RESULTS = ["results.jsonl", "results-opus-luna.jsonl", "results-sol61.jsonl", "results-astra.jsonl",
           "results-sonnet55.jsonl", "results-gpt55.jsonl"]


def _load_json(rel: str):
    return json.loads((REPO / rel).read_text())


def gm(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def fint(x) -> str:
    return f"{x:,.0f}"


def scored_rows() -> dict[str, list[dict]]:
    sys.path.insert(0, str(REPO / "research/v2/scripts"))
    from analyze_main import load  # noqa: E402
    scored, _ = load([REPO / "bench/v2" / f for f in RESULTS], [RUN / "incident_08/holdout_rescored.jsonl"])
    out: dict[str, list[dict]] = {}
    for (model, _), row in scored.items():
        out.setdefault(model, []).append(row)
    return out


def chart_runs(final: dict, xf: dict, refs: dict[str, float]) -> str:
    """Dot plot: one row per system, one dot per scored run, a bar at the
    geometric mean; dashed verticals for VexRiscv MaxPerf, the textbook
    edit and V0."""
    W, ML, MR, MT, ROW = 960, 150, 30, 46, 46
    order = [r["system"] for r in final["ranking"]]
    H = MT + ROW * len(order) + 44
    xmax = 8000.0
    pw = W - ML - MR

    def X(v):
        return ML + pw * v / xmax

    parts = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Held-out score of every scored V2 run, by system" class="chart">']
    for t in range(0, 8001, 1000):
        x = X(t)
        parts.append(f'<line class="grid" x1="{x:.1f}" y1="{MT - 10}" x2="{x:.1f}" y2="{H - 34}"/>')
        parts.append(f'<text class="tick" x="{x:.1f}" y="{H - 18}" text-anchor="middle">{t:,}</text>')
    parts.append(f'<text class="axis-label" x="{ML + pw / 2:.1f}" y="{H - 2}" text-anchor="middle">'
                 'held-out score (iterations per second on five hidden programs)</text>')
    ref_style = {"VexRiscv MaxPerf": ("var(--c-human)", "human reference"),
                 "textbook edit": ("var(--ink-muted)", "textbook edit"), "V0": ("var(--ink-muted)", "V0 start")}
    for i, (name, v) in enumerate(refs.items()):
        x = X(v)
        color, label = ref_style[name]
        parts.append(f'<line x1="{x:.1f}" y1="{MT - 14}" x2="{x:.1f}" y2="{H - 34}" stroke="{color}" '
                     f'stroke-width="1" stroke-dasharray="4 3" data-tip="{name}: {fint(v)} iter/s"/>')
        parts.append(f'<text class="tick" x="{x + 4:.1f}" y="{MT - 18 - (i % 2) * 12}" fill="{color}" '
                     f'style="fill:{color}">{label} {fint(v)}</text>')
    by_sys: dict[str, list[dict]] = {}
    for r in xf["runs"]:
        by_sys.setdefault(r["system"], []).append(r)
    for i, s in enumerate(order):
        _, disp, cli, color = SYSTEMS[s]
        y = MT + ROW * i + ROW / 2
        parts.append(f'<text class="axis-label" x="{ML - 12}" y="{y - 3:.1f}" text-anchor="end">{disp}</text>')
        parts.append(f'<text class="tick" x="{ML - 12}" y="{y + 11:.1f}" text-anchor="end">{cli}</text>')
        g = next(r["geomean"] for r in final["ranking"] if r["system"] == s)
        parts.append(f'<line x1="{X(g):.1f}" y1="{y - 13:.1f}" x2="{X(g):.1f}" y2="{y + 13:.1f}" stroke="{color}" '
                     f'stroke-width="3" data-tip="{disp}: geometric mean {fint(g)} iter/s over 6 runs"/>')
        for r in sorted(by_sys[s], key=lambda r: r["rep"]):
            parts.append(f'<circle class="point" cx="{X(r["gowin_heldout"]):.1f}" cy="{y:.1f}" r="6" fill="{color}" '
                         f'fill-opacity="0.75" data-tip="{disp} run {r["rep"]}: {fint(r["gowin_heldout"])} iter/s, '
                         f'{r["gowin_fmax"]:.1f} MHz"/>')
    parts.append("</svg>")
    return "\n".join(parts)


def render(stars=None) -> str:
    final = json.loads((RUN / "analysis_final.json").read_text())
    abl = json.loads((RUN / "analysis_ablation.json").read_text())
    xf = _load_json("research/v2/xfpga/results/analysis.json")
    rc = _load_json("research/v2/random_control/analysis.json")
    tb = _load_json("research/v2/textbook_baseline/results/textbook.json")
    v0 = _load_json("research/v2/textbook_baseline/results/v0.json")
    names = {r["key"]: r["name"] for r in _load_json("research/v2/reference_cores/references.json")}
    rows = scored_rows()

    tb_ho = tb["holdout"]["geomean_iter_s"]
    v0_ho = v0["holdout"]["geomean_iter_s"]
    vex = next(r for r in xf["refs"] if r["design"] == "vexriscv_maxperf")
    refs = {"VexRiscv MaxPerf": vex["gowin_heldout"], "textbook edit": tb_ho, "V0": v0_ho}

    # Table 1.
    t1 = []
    for r in final["ranking"]:
        model, disp, cli, _ = SYSTEMS[r["system"]]
        rs = rows[model]
        t1.append(f"""
    <tr>
      <td><span class="model-name">{disp}</span> <span class="tick-cli">({cli})</span></td>
      <td class="num">{fint(r['geomean'])}</td>
      <td class="num">{r['rank95'][0]} to {r['rank95'][1]}</td>
      <td class="num">{gm([x['final_fitness'] for x in rs]):.0f}</td>
      <td class="num">{statistics.median([x['holdout_fmax_mhz'] for x in rs]):.1f}</td>
      <td class="num">{fint(statistics.median([x['best_lut4'] for x in rs]))}</td>
    </tr>""")
    t1.append(f"""
    <tr class="human-baseline">
      <td><span class="model-name">VexRiscv MaxPerf</span> (human, best of ten reference cores)</td>
      <td class="num">{fint(vex['gowin_heldout'])}</td><td class="num"></td><td class="num"></td>
      <td class="num">{vex['gowin_fmax']:.1f}</td><td class="num"></td>
    </tr>
    <tr class="baseline-row">
      <td><span class="model-name">textbook edit</span> (V0 with an iterative divider)</td>
      <td class="num">{fint(tb_ho)}</td><td class="num"></td><td class="num">103.7</td>
      <td class="num">{tb['fpga']['fmax_mhz']:.1f}</td><td class="num">{fint(tb['fpga']['lut4'])}</td>
    </tr>
    <tr class="baseline-row">
      <td><span class="model-name">V0</span> (every run starts here)</td>
      <td class="num">{fint(v0_ho)}</td><td class="num"></td><td class="num">12.1</td>
      <td class="num">{v0['fpga']['fmax_mhz']:.1f}</td><td class="num">{fint(v0['fpga']['lut4'])}</td>
    </tr>""")

    p = final["primary"]
    ext = final["extension"]
    sep = sum(1 for v in ext.values() if v["p_holm"] < 0.05 and (v["ci95"][0] > 1 or v["ci95"][1] < 1))
    at = abl["test"]

    # Artix-7 table.
    art = []
    for s in sorted(xf["systems"], key=lambda s: -s["gowin_heldout_gm"]):
        _, disp, _, _ = SYSTEMS[s["system"]]
        art.append(f"""
    <tr><td><span class="model-name">{disp}</span></td>
      <td class="num">{fint(s['gowin_heldout_gm'])}</td><td class="num">{fint(s['artix_heldout_gm'])}</td>
      <td class="num">{s['artix_fmax_gm'] / s['gowin_fmax_gm']:.2f}</td></tr>""")
    for key in ("vexriscv_maxperf", "vexriscv_nocache"):
        r = next(r for r in xf["refs"] if r["design"] == key)
        art.append(f"""
    <tr class="human-baseline"><td><span class="model-name">{names[key]}</span> (human)</td>
      <td class="num">{fint(r['gowin_heldout'])}</td><td class="num">{fint(r['artix_heldout'])}</td>
      <td class="num">{r['artix_fmax'] / r['gowin_fmax']:.2f}</td></tr>""")
    xa = xf["tests_artix"]["primary"]["Opus vs Sol 6.1"]
    fr = xf["fmax_ratio"]

    slots = rc["slots"]
    n_slots = len(slots)
    gates = {g: sum(1 for s in slots if s["gate"] == g) for g in ("improvement", "regression", "formal_failed", "cosim_failed")}

    hd = head("HWE Bench · V2 results", "v2", stars)
    return hd + f"""
<section class="hero-block">
  <div class="hero-eyebrow">V2 · October 2026 · six agent systems · 36 scored runs</div>
  <h1 class="hero">V2 results</h1>
  <p class="hero-lede">
    V2 rebuilt the score after V1's open-source timer turned out to miss whole classes of
    circuit paths. Every design is now timed by the FPGA vendor's own tool, with memory stalls
    present in the timed circuit, and ranked on five hidden programs the agents never see.
    Six agent systems (a model inside its vendor's command-line agent) each ran six times from
    the same starting core, 15 rounds of 3 attempts per run.
  </p>
  <div class="hero-thesis">
    <span class="label">Result</span>
    Three tiers: Opus 5.5 and Sonnet 5.5 (Claude Code), then GPT-6.1 Sol and GPT-6 Astra
    (Codex CLI), then GPT-5.5 and GPT-6 Luna (Codex CLI). Pre-registered test, Opus 5.5 vs
    GPT-6.1 Sol: {p['ratio']:.2f}x, 95% CI {p['ci95'][0]:.2f} to {p['ci95'][1]:.2f}, p = {p['p']:.4f}.
  </div>
</section>

<section class="section">
  <div class="eyebrow">Every scored run</div>
  <h2>Held-out score per run</h2>
  <figure class="chart">
    {chart_runs(final, xf, refs)}
    <figcaption>
      One dot per scored run (six per system), the bar is the system's geometric mean.
      Held-out score = the design's maximum clock frequency (Gowin EDA, GW2A-18) times the
      geometric mean of iterations per cycle on five benchmark programs the agents never saw.
      Dashed lines: VexRiscv MaxPerf, the best of ten human-designed reference cores on the same
      flow; the textbook edit (V0 plus an iterative divider); V0, the starting core.
    </figcaption>
  </figure>
</section>

<section class="section">
  <div class="eyebrow">Final designs</div>
  <h2>Six systems, six runs each</h2>
  <div class="wide">
  <table class="bench">
    <caption>Geometric means over 6 runs; Fmax and LUT4 are medians. Rank interval: 95% bootstrap.
      Blank cells do not apply. Harness 2.8.2 for every scored run.</caption>
    <thead><tr>
      <th>System (agent CLI)</th><th class="num">Held-out iter/s</th><th class="num">Rank interval</th>
      <th class="num">CoreMark iter/s</th><th class="num">Fmax (MHz)</th><th class="num">Area (LUT4)</th>
    </tr></thead>
    <tbody>{''.join(t1)}
    </tbody>
  </table>
  </div>
  <div class="prose">
  <p>
    The pre-registered comparison, Opus 5.5 against GPT-6.1 Sol, separates:
    ratio {p['ratio']:.3f} [{p['ci95'][0]:.3f}, {p['ci95'][1]:.3f}], p = {p['p']:.4f}.
    Of the 12 further pairs (Holm-corrected), {sep} separate. The three that do not are the
    pairs inside each tier: Opus 5.5 vs Sonnet 5.5, GPT-6.1 Sol vs GPT-6 Astra, and
    GPT-5.5 vs GPT-6 Luna. Six runs per system resolve differences of about 20%, not the
    6 to 10% gaps inside a tier.
  </p>
  </div>
</section>

<section class="section">
  <div class="eyebrow">Baselines and controls</div>
  <h2>What the agents beat</h2>
  <dl class="defs">
    <dt>Textbook edit</dt>
    <dd>V0's single-cycle divider replaced by a radix-2 iterative one, the first move most
      agents make (34 of the 35 designs accepted in round 1 change the divider). It passes every
      gate and scores {fint(tb_ho)} held-out iter/s, 8.6x V0, all of it clock frequency. Every
      scored run beats it; system means are 1.3x (GPT-6 Luna) to 2.7x (Opus 5.5) its score.</dd>
    <dt>Random-mutation control</dt>
    <dd>No model: 1 to 3 random single-line edits per attempt (swapped operators, changed
      constants), {n_slots} attempts over 3 runs. {gates['improvement']} accepted:
      {gates['formal_failed']} fail formal verification, {gates['cosim_failed']} fail
      co-simulation against an instruction-set simulator, {gates['regression']} pass every gate
      but change nothing the design does. The gates do not hand out improvements to blind edits.</dd>
    <dt>Lessons ablation</dt>
    <dd>GPT-6.1 Sol run six more times without the lessons file (one-line notes an agent writes
      after each attempt for later rounds). Full vs no lessons: {at['ratio']:.2f}x, 95% CI
      {at['ci95'][0]:.2f} to {at['ci95'][1]:.2f}, p = {at['p']:.2f}. Not distinguishable; the
      interval rules out a gain from the lessons above about 14%.</dd>
    <dt>Human reference cores</dt>
    <dd>Ten open-source RV32IM cores built on the same flow with the same stall model. VexRiscv
      MaxPerf ({fint(vex['gowin_heldout'])}) falls between the first and second tiers; the other nine
      score below every second-tier system.</dd>
  </dl>
</section>

<section class="section">
  <div class="eyebrow">Robustness</div>
  <h2>Does the ranking hold?</h2>
  <div class="prose">
  <p>
    <strong>Place-and-route settings.</strong> All final designs rebuilt under the six Gowin
    placement and routing settings that change a build: the same system order, Opus 5.5 vs
    GPT-6.1 Sol between 1.28x and 1.33x (every p &lt; 0.001), and the same 9 of 12 separating
    pairs under every setting.
  </p>
  <p>
    <strong>Unseen programs.</strong> On 15 more Embench-IoT programs no agent saw, the system
    order, the rank intervals and the three indistinguishable pairs are the same; all 740
    design-program runs give correct results.
  </p>
  <p>
    <strong>Another FPGA.</strong> Every design synthesized for an AMD Artix-7 with Vivado. The
    split between the top four and the bottom two holds; the order inside the top four does not
    (Opus 5.5 vs GPT-6.1 Sol: {xa['ratio']:.2f}x, p = {xa['p']:.2f}). The agents' designs gain less
    from the faster fabric than the human cores (Fmax ratio {fr['agents_gm']:.2f} vs
    {fr['refs_gm']:.2f}), which suggests that fifteen rounds of tuning against one vendor's
    timing report fit a design to that part. The V2 ranking is a ranking on the Gowin contract.
  </p>
  </div>
  <div class="wide">
  <table class="bench">
    <caption>Held-out score on each FPGA, geometric means over 6 runs; Fmax ratio Artix-7 / Gowin.</caption>
    <thead><tr><th>System</th><th class="num">Gowin GW2A-18</th><th class="num">Artix-7 200T</th>
      <th class="num">Fmax ratio</th></tr></thead>
    <tbody>{''.join(art)}
    </tbody>
  </table>
  </div>
</section>

<section class="section">
  <div class="eyebrow">Correctness</div>
  <h2>What the gates missed</h2>
  <div class="prose">
  <p>
    Three gaps in the correctness checks surfaced during and after scoring; none changes a
    scored result.
  </p>
  <ul>
    <li><strong>Instruction fetch address.</strong> No gate proves that the fetch address stays
      inside memory. A bounded formal check written after scoring (any 64-word program whose own branches stay in range,
      arbitrary memory stalls, 20 cycles from reset) passes 36 of 44 designs and finds one
      failure: an Opus 5.5 design fetches from below address 0 on a mispredicted path, 9 cycles
      after reset. Its results stay correct. Seven larger designs time out without a
      counterexample.</li>
    <li><strong>Multiply and divide arithmetic.</strong> The per-round formal gate replaces
      multiplier and divider results with stand-in formulas, so co-simulation checks the
      arithmetic. The vendored formal specification for signed DIV and REM computes the
      unsigned result, so the contract's full-arithmetic check fails every correct divider.</li>
    <li><strong>Formal saw different code.</strong> Two final designs gave the formal tool a
      different version of one block than synthesis and simulation got. Both pass all 53 checks
      when formal sees the synthesized version.</li>
  </ul>
  </div>
</section>

<section class="section">
  <div class="eyebrow">From V1 to V2</div>
  <h2>What changed, and what V1 got wrong</h2>
  <div class="wide">
  <table class="bench">
    <thead><tr><th>V1</th><th>V2</th></tr></thead>
    <tbody>
    <tr><td>Open-source timer (nextpnr): misses whole path classes, a 32-bit divider timed at
      123 MHz that the vendor tool times at 6.9 MHz</td><td>Vendor timer (Gowin EDA) for scoring
      and for the agents</td></tr>
    <tr><td>Memory stalls simulated but absent from the timed circuit, so stall logic was free</td>
      <td>The same stall generator in simulation and in the timed circuit</td></tr>
    <tr><td>Scored on CoreMark, the program the agents optimize</td><td>Scored on five hidden
      programs; CoreMark stays the optimization signal</td></tr>
    <tr><td>Any improvement accepted</td><td>A 4.6% margin, set from measured placement noise</td></tr>
    <tr><td>2 to 3 runs per model, best run reported</td><td>6 runs per system, pre-registered
      tests, geometric means</td></tr>
    <tr><td>Read access differed by CLI (Codex agents could read anything)</td><td>One OS account
      per concurrent run, the same rules for every CLI, hidden programs unreadable</td></tr>
    <tr><td>Random-mutation control: 0 of 135 accepted, but a seeding bug made it 3 draws
      repeated 45 times</td><td>135 independent draws, 0 accepted</td></tr>
    </tbody>
  </table>
  </div>
  <p class="prose">
    The <a href="index.html">leaderboard on the home page</a> is V1's: its numbers come from the
    open-source timer and are not comparable with these.
  </p>
</section>

<section class="section">
  <div class="eyebrow">Data</div>
  <h2>Everything is in the repository</h2>
  <div class="prose">
  <ul>
    <li><a href="{GH_V2}/research/runs/EXP-2026-09-28-v2-main" class="ext">Pre-registration,
      amendments and analyses</a> (index in its README)</li>
    <li><a href="{GH_V2}/bench/v2" class="ext">Every run</a>: final RTL, per-attempt log,
      lessons file, full agent transcripts, git history</li>
    <li><a href="{GH_V2_BLOB}/research/v2/NOTES.md" class="ext">Day-by-day research notes</a>,
      including every incident that stopped a campaign</li>
    <li><a href="{GH_V2_BLOB}/research/v2/V3.md" class="ext">What V2 does not fix</a></li>
  </ul>
  </div>
</section>
""" + FOOTER.replace("methodology v1", "methodology v2")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, default=REPO / "site")
    a = ap.parse_args()
    (a.out / "v2.html").write_text(render())
    print(f"wrote {a.out / 'v2.html'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
