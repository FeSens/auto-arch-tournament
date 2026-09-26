"""Per-configuration run notes and sample-size caveats for the site.

build.py renders a configuration's note on the models page, under its
heading, and the single-repetition caveat under the index leaderboard.
Notes hold only facts that do not change when a run's final row lands;
numbers come from bench/results.jsonl and the rep journals.
"""
from __future__ import annotations

REPO_BLOB = "https://github.com/FeSens/auto-arch-tournament/blob/main/"

# model name -> {"runtime": html, "readme": repo path, "paragraphs": [html]}
RUN_NOTES = {
    "claude-opus-5_5_xhigh": {
        "runtime": (
            'Claude Opus 5.5 via Claude Code 2.1.282 · '
            'reasoning effort <span class="mono">xhigh</span> · '
            'subscription (OAuth) login · 15 rounds × 3 hypotheses per round.'
        ),
        "readme": "bench/claude-opus-5_5_xhigh/README.md",
        "paragraphs": [
            "Isolation: no user settings, plugins, hooks, MCP servers, connectors "
            "or auto-memory. Bash ran in a sandbox with no network, writes confined "
            "to the rep's clone and reads of the operator's home directory denied. "
            "Web tools were disabled, and the clone sat outside the repository, so "
            "no parent CLAUDE.md was loaded.",
            "The scored repetition is the second launch. The first was stopped in "
            "round 8 by a harness bug (an agent's formal self-check could delete the "
            "harness's live formal work directory) and is kept but not scored.",
            "Most broken slots are hypothesis agents that reached the 20-minute "
            "limit, the same for every model, while running their own synthesis "
            "and place-and-route experiments, without writing a hypothesis.",
            "Caveats on accepted designs. CoreMark cycles are measured with random "
            "bus backpressure, but Fmax and area come from a bench wrapper with the "
            "memory ready signals tied high, so logic that only hides stalls costs no "
            "area or timing. Some accepted designs here contain such logic, as do "
            "accepted designs of other configurations; its share of the score is "
            "unmeasured. One accepted change made the divider slower, which is "
            "cycle-neutral because CoreMark's timed window retires no divides. "
            "Another partly optimizes the verification-only RVFI order counter. "
            "The LUT4 figures exclude LUT-RAM and block RAM, which later designs "
            "use for the register file.",
            "Dollar billing is unavailable under OAuth, so the $0.00 cost is not "
            "measured zero spend. Token totals cover every agent (hypothesis, "
            "implementer and scribe); output tokens are a lower bound for sessions "
            "stopped by the timeout.",
        ],
    },
}


def render_run_note(agg) -> str:
    """HTML note for one configuration, or "" when it has none."""
    note = RUN_NOTES.get(agg.model)
    if not note:
        return ""
    if agg.n_total == 1:
        sample = ("One repetition (n=1): repeatability has not been measured, "
                  "and any ranking against other configurations is untested.")
    else:
        sample = f"{agg.n_total} independent repetitions recorded."
    parts = [f'<p class="prose">{note["runtime"]} {sample}</p>']
    parts += [f'<p class="prose">{p}</p>' for p in note["paragraphs"]]
    parts.append(
        f'<p class="prose"><a href="{REPO_BLOB}{note["readme"]}" class="ext">'
        'Run notes, launch history and caveats</a>.</p>')
    return "\n".join(parts)


def _is_control(name: str) -> bool:
    # Mirrors build.is_control_model; kept local to avoid a circular import.
    return (name in {"static", "random-mutation"}
            or name.startswith("naive-") or name.startswith("static-"))


def render_single_rep_caveat(aggs) -> str:
    """Leaderboard footnote naming scored one-rep configurations.

    Limited to configurations with a run note (added from Opus 5.5 on);
    earlier one-rep rows keep their published presentation.
    """
    single = [a.model for a in aggs
              if a.model in RUN_NOTES and a.n_total == 1
              and a.fitness_best is not None and not _is_control(a.model)]
    if not single:
        return ""
    names = ", ".join(f"<code>{m}</code>" for m in single)
    return (
        '<p class="prose">Single repetition (n=1): '
        f"{names}. Each of these rows is one run; repeatability is unmeasured, "
        "so rank differences involving them are untested.</p>"
    )


def leader_sample_caveat(agg) -> str:
    """Inline caveat for a headline number that comes from a one-rep config."""
    if agg is None or agg.n_total != 1:
        return ""
    return " (one repetition, n=1; untested)"
