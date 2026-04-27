"""Generates experiments/progress.png after every accepted merge."""
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from pathlib import Path

LOG_PATH = Path("experiments/log.jsonl")
OUT_PATH = Path("experiments/progress.png")

TARGET = 370  # goal line — dashed red, no annotation

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

    fig, ax = plt.subplots(figsize=(12, 5))

    # Scatter all experiments
    for i, e in enumerate(entries):
        if 'fitness' in e and e['fitness'] is not None:
            c = color_map.get(e.get('outcome', 'broken'), '#bdc3c7')
            s = size_for(e.get('lut4'))
            ax.scatter(i, e['fitness'], color=c, s=s, zorder=3,
                       edgecolors='white', linewidths=0.6)

    # Champion path (solid black line through accepted improvements)
    best = 0.0
    champ_x, champ_y = [], []
    for i, e in enumerate(entries):
        if e.get('outcome') == 'improvement' and e.get('fitness'):
            best = e['fitness']
        if best > 0:
            champ_x.append(i)
            champ_y.append(best)
    if champ_x:
        ax.plot(champ_x, champ_y, color='black', linewidth=1.8, zorder=2)

    # Target line — dashed red, no label or annotation
    ax.axhline(y=TARGET, color='red', linestyle='--', linewidth=1.2, zorder=1)

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
