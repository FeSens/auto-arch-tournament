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

    fig, ax = plt.subplots(figsize=(12, 5))

    # Scatter all experiments
    for i, e in enumerate(entries):
        if 'fitness' in e and e['fitness'] is not None:
            c = color_map.get(e.get('outcome', 'broken'), '#bdc3c7')
            ax.scatter(i, e['fitness'], color=c, s=40, zorder=3)

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
    ax.set_title('CoreMark Performance Evolution')
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    fig.tight_layout()

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(OUT_PATH), dpi=150)
    plt.close(fig)

if __name__ == '__main__':
    plot_progress()
