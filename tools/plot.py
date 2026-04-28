"""Generates experiments/progress.png after every accepted merge."""
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from pathlib import Path

LOG_PATH = Path("experiments/log.jsonl")
OUT_PATH = Path("experiments/progress.png")

# VexRiscv "full no cache" reference: 2.57 CoreMark/MHz × 144 MHz median Fmax
# on this FPGA = ~370 iter/s.
VEX_CM_PER_MHZ = 2.57
VEX_FMAX_MHZ   = 144
VEXRISCV_REF   = VEX_CM_PER_MHZ * VEX_FMAX_MHZ   # ~370 iter/s

def plot_progress():
    if not LOG_PATH.exists():
        return

    entries = [json.loads(l) for l in LOG_PATH.read_text().splitlines() if l.strip()]
    if not entries:
        return

    color_map = {
        'improvement':     '#2ecc71',
        'regression':      '#e67e22',
        'broken':          '#bdc3c7',
        'placement_failed':'#bdc3c7',
    }

    # Dot size ∝ LUT4 footprint of each candidate. Normalized across this
    # log so the smallest design renders at DOT_MIN_PT2 and the largest at
    # DOT_MAX_PT2 — fitness gains that come from going wider/bigger jump
    # out visually instead of looking the same as a free win on the same
    # transistor budget.
    DOT_MIN_PT2, DOT_MAX_PT2 = 30.0, 320.0
    DOT_DEFAULT_PT2 = 60.0  # fallback for entries with no lut4 (broken)
    lut4s = [e.get('lut4') for e in entries
             if isinstance(e.get('lut4'), (int, float)) and e['lut4'] > 0]
    lut4_min = min(lut4s) if lut4s else None
    lut4_max = max(lut4s) if lut4s else None

    def size_for(lut4):
        if not lut4 or lut4_min is None:
            return DOT_DEFAULT_PT2
        if lut4_max == lut4_min:
            return (DOT_MIN_PT2 + DOT_MAX_PT2) / 2
        norm = (lut4 - lut4_min) / (lut4_max - lut4_min)
        return DOT_MIN_PT2 + norm * (DOT_MAX_PT2 - DOT_MIN_PT2)

    # Map each entry to its x position. Tournament rounds collapse: every
    # slot sharing a round_id lands at the same iteration, so the graph
    # shows like-vs-like fitness comparisons stacked at one x. Legacy
    # entries (no round_id) advance the x counter normally.
    x_for_entry: list[int] = []
    round_x: dict[int, int] = {}
    next_x = 0
    for e in entries:
        rid = e.get('round_id')
        if isinstance(rid, int):
            if rid not in round_x:
                round_x[rid] = next_x
                next_x += 1
            x_for_entry.append(round_x[rid])
        else:
            x_for_entry.append(next_x)
            next_x += 1

    fig, ax = plt.subplots(figsize=(12, 5))

    # Round-banding: a faint vertical strip at each round's x when 2+ slots
    # share it. Alternates shade by round parity for visual separation.
    for rid, x in round_x.items():
        slots_in_round = sum(1 for e in entries if e.get('round_id') == rid)
        if slots_in_round < 2:
            continue
        shade = '#3498db' if rid % 2 == 0 else '#9b59b6'
        ax.axvspan(x - 0.4, x + 0.4, color=shade, alpha=0.08, zorder=0)

    # Scatter all experiments
    for i, e in enumerate(entries):
        if 'fitness' in e and e['fitness'] is not None:
            c = color_map.get(e.get('outcome', 'broken'), '#bdc3c7')
            s = size_for(e.get('lut4'))
            ax.scatter(x_for_entry[i], e['fitness'], color=c, s=s, zorder=3,
                       edgecolors='white', linewidths=0.6)

    # Champion path: one (x, best-so-far) point per unique iteration.
    best = 0.0
    champ_x, champ_y = [], []
    for i, e in enumerate(entries):
        if e.get('outcome') == 'improvement' and e.get('fitness'):
            best = e['fitness']
        if best > 0:
            x = x_for_entry[i]
            if champ_x and champ_x[-1] == x:
                champ_y[-1] = best
            else:
                champ_x.append(x)
                champ_y.append(best)
    if champ_x:
        ax.plot(champ_x, champ_y, color='black', linewidth=1.8, zorder=2)

    # Reference lines: baseline (first improvement entry) + VexRiscv-comparable.
    baseline_fit = next(
        (e.get('fitness') for e in entries
         if e.get('outcome') == 'improvement' and isinstance(e.get('fitness'), (int, float))),
        None,
    )
    if baseline_fit:
        ax.axhline(y=baseline_fit, color='#7f8c8d', linestyle=':',
                   linewidth=1.2, zorder=1, alpha=0.85)
        ax.text(next_x - 0.3, baseline_fit, f' baseline {baseline_fit:.0f} iter/s',
                va='center', ha='right', fontsize=9, color='#7f8c8d')

    ax.axhline(y=VEXRISCV_REF, color='red', linestyle='--',
               linewidth=1.2, zorder=1)
    ax.text(next_x - 0.3, VEXRISCV_REF,
            f' VexRiscv {VEX_CM_PER_MHZ} CM/MHz @ {VEX_FMAX_MHZ} MHz',
            va='bottom', ha='right', fontsize=9, color='red')

    ax.set_xlabel('Iteration')
    ax.set_ylabel('CoreMark iter/sec')
    title = 'CoreMark Performance Evolution'
    if lut4_min is not None:
        if lut4_min == lut4_max:
            title += f'  (dot size ∝ LUT4 ≈ {lut4_min:,})'
        else:
            title += f'  (dot size ∝ LUT4: {lut4_min:,}–{lut4_max:,})'
    ax.set_title(title)
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    fig.tight_layout()

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(OUT_PATH), dpi=150)
    plt.close(fig)

if __name__ == '__main__':
    plot_progress()
