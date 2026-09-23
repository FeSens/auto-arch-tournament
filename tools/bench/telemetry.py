"""Post-run telemetry for bench reps: token/cost parsing per agent
runtime, agent-transcript collection, log.jsonl reconstruction from git,
and the per-rep summary row. Split out of tools/bench/runner.py, which
re-exports every name here for existing importers.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


def parse_codex_cost_from_log(log_path: Path) -> tuple[int, int, float]:
    """Sum input/output tokens across a codex --json log.

    Codex emits one event per agent turn:
      {"type":"turn.completed","usage":{"input_tokens":N,
        "cached_input_tokens":N,"output_tokens":N,"reasoning_output_tokens":N}}

    `cached_input_tokens` is a *subset* of `input_tokens` (the prompt
    portion already in the model's KV cache). We sum the gross
    `input_tokens` so the count reflects what the model actually
    processed — callers who want billable-only tokens can subtract
    cache reads via the rate card.

    Cost is always 0.0: codex via OAuth subscription doesn't expose
    per-call billing, and even paid-API codex doesn't emit `cost` in
    its stream-json schema. Apply pricing externally if needed.

    Dedup: collect_agent_logs concatenates the same hypothesis log
    multiple times because both the explicit hypotheses dir AND the
    clone-root rglob pick it up. Without per-line dedup we'd
    double-count every turn. The fix in collect_agent_logs is to use
    a set of paths, but the per-line dedup here is a defensive
    backstop in case any future log path changes re-introduce dupes.
    """
    if not log_path.is_file():
        return (0, 0, 0.0)
    seen: set[str] = set()
    toks_in = toks_out = 0
    for raw in log_path.read_text().splitlines():
        s = raw.strip()
        if not s.startswith("{") or '"turn.completed"' not in s:
            continue
        if s in seen:
            continue
        seen.add(s)
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "turn.completed":
            continue
        usage = ev.get("usage") or {}
        if not isinstance(usage, dict):
            continue
        try:
            toks_in += int(usage.get("input_tokens") or 0)
            # OpenAI reasoning models report `output_tokens` (visible
            # response + tool-call output) separately from
            # `reasoning_output_tokens` (chain-of-thought, not visible
            # but billed at the output rate). Sum both so the headline
            # output number matches actual model work and matches
            # opencode's normalization (tokens.output + tokens.reasoning).
            toks_out += int(usage.get("output_tokens") or 0)
            toks_out += int(usage.get("reasoning_output_tokens") or 0)
        except (TypeError, ValueError):
            pass
    return (toks_in, toks_out, 0.0)


def parse_opencode_cost_from_log(log_path: Path) -> tuple[int, int, float]:
    """Sum input/output tokens and cost across an opencode --format json log.

    Opencode emits a `step_finish` event after each turn carrying the
    cumulative `tokens` and `cost` for that step:
      {"type":"step_finish", ..., "part":{"tokens":{"input":N,"output":N,
        "reasoning":N,"cache":{"read":N,"write":N}}, "cost":F, ...}}

    `tokens.input` is the *uncached* portion of the prompt; cache hits
    are reported separately under `tokens.cache.read`. To stay
    consistent with parse_codex_cost_from_log (which sums codex's gross
    `input_tokens` per turn — cache included), we count opencode's
    gross input as `tokens.input + tokens.cache.read + tokens.cache.write`.
    Without this normalization an apples-to-apples comparison with
    codex showed a 15× gap that was almost entirely cache-accounting,
    not actual model work — codex's xhigh n10 run reported 16.3M
    "input" of which 14M was cached re-reads of the same prompt;
    opencode at xhigh did the equivalent ~10M (1.1M new + 9.1M cache
    reads) but the saved row read as 1.1M because cache.read was
    skipped. Cumulative effect: the bench underreported opencode's
    token usage by ~10×.

    `cost: 0` is normal under OAuth subscriptions (no per-token
    billing); we still tally token counts regardless.

    cache.write is normally 0 under OpenAI; including it costs nothing
    when 0 and keeps the field semantics correct if a model family
    starts populating it (Anthropic, etc.).
    """
    if not log_path.is_file():
        return (0, 0, 0.0)
    toks_in = toks_out = 0
    cost = 0.0
    for raw in log_path.read_text().splitlines():
        s = raw.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            ev = json.loads(s)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "step_finish":
            continue
        part = ev.get("part") or {}
        if not isinstance(part, dict):
            continue
        toks = part.get("tokens") or {}
        if isinstance(toks, dict):
            ti = toks.get("input") or 0
            to = toks.get("output") or 0
            cache = toks.get("cache") or {}
            cr = cache.get("read", 0) if isinstance(cache, dict) else 0
            cw = cache.get("write", 0) if isinstance(cache, dict) else 0
            tr = toks.get("reasoning") or 0
            try:
                toks_in += int(ti) + int(cr or 0) + int(cw or 0)
                # Sum visible output + reasoning. opencode reports
                # them separately; both are billed as output. Matches
                # the codex parser, which sums output_tokens +
                # reasoning_output_tokens for the same reason.
                toks_out += int(to) + int(tr or 0)
            except (TypeError, ValueError):
                pass
        c = part.get("cost", 0)
        try:
            cost += float(c or 0)
        except (TypeError, ValueError):
            pass
    return (toks_in, toks_out, cost)


def reconstruct_log_from_git(clone: Path, target: str = "bench") -> list[str] | None:
    """Walk the rep clone's git history (across all reachable refs +
    reflog) and recover every line ever written to
    cores/<target>/experiments/log.jsonl.

    Why: orchestrator.append_log auto-commits each iteration's entry
    as `log: <id> <outcome>`. The commits are append-only and survive
    HEAD-rewinding bugs (we hit one earlier — the bench-fixture-v1
    tag/branch ambiguity caused mid-run rewinds that orphaned earlier
    rounds, but the commits themselves stayed in the object DB).
    Walking the reflog plus all reachable refs recovers them.

    Strategy:
      1. List every commit reachable from any ref OR the reflog whose
         message starts with `log: hyp-` (per the orchestrator's
         commit-message convention) — use --walk-reflogs and --all.
      2. For each commit, `git show <sha>:cores/<target>/experiments/
         log.jsonl` and take the LAST line — append_log writes one
         entry per commit, so the new line is always at EOF.
      3. Dedup by hypothesis id (different commits might re-write the
         same entry).
      4. Sort by (round_id, slot) so the reconstructed log is in
         logical order even if the underlying commit graph isn't.

    Returns:
      list of JSONL lines (one per iteration) or None if no commits
      matched. Caller compares to the on-disk file and uses whichever
      is more complete.
    """
    log_path = f"cores/{target}/experiments/log.jsonl"
    cwd = str(clone.resolve())
    # All commits across refs + reflog with the orchestrator's
    # canonical commit message prefix. --walk-reflogs covers the
    # orphaned-by-rewind case.
    # `^log: ` matches both per-iteration `log: hyp-...` commits and
    # the orchestrator-emitted `log: baseline-<target>-<sha> improvement`
    # commit (round_id=0). Including the baseline lets summarize_run's
    # round_id=0 path produce the canonical baseline_fitness anchor.
    out = subprocess.run(
        ["git", "log", "--all", "--reflog", "--format=%H",
         "--grep=^log: ", "--", log_path],
        cwd=cwd, capture_output=True, text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        return None
    shas = out.stdout.strip().splitlines()
    by_id: dict[str, dict] = {}
    for sha in shas:
        proc = subprocess.run(
            ["git", "show", f"{sha}:{log_path}"],
            cwd=cwd, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            continue
        # The last non-empty line is the entry this commit added (the
        # rest are pre-existing). append_log always writes one new line.
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        if not lines:
            continue
        try:
            entry = json.loads(lines[-1])
        except json.JSONDecodeError:
            continue
        eid = entry.get("id")
        if not eid:
            continue
        # Keep the first occurrence per id; commit ordering is not
        # author-stable, but content stability is what we need.
        if eid not in by_id:
            by_id[eid] = entry
    if not by_id:
        return None
    ordered = sorted(
        by_id.values(),
        key=lambda e: (e.get("round_id", 0), e.get("slot", 0)),
    )
    return [json.dumps(e) for e in ordered]


def collect_agent_logs(clone: Path) -> Path:
    """Concatenate every per-iteration .agent.*.log into one stream.

    Returns path to the concatenated file (in /tmp); the runner copies
    that into bench/<model>/<rep>/agent.log afterward.
    """
    out_path = clone / ".tmp" / "agent.concatenated.log"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Dedup paths: the recursive rglob from `clone` re-finds every
    # .agent*.log under cores/bench/experiments/hypotheses/, so without
    # a set the concat lists each hypothesis log twice. Token parsers
    # also dedup defensively, but fixing it here makes the file shape
    # what the comments describe.
    parts: set[Path] = set()
    for sub in (
        clone / "cores" / "bench" / "experiments" / "hypotheses",
        clone,  # implementation worktrees write .agent.log at root of their dir
    ):
        if sub.is_dir():
            parts.update(sub.rglob(".agent*.log"))
    with out_path.open("w") as outf:
        for p in sorted(parts):
            try:
                outf.write(f"=== {p} ===\n")
                outf.write(p.read_text())
                outf.write("\n")
            except OSError:
                continue
    return out_path


def parse_cost_from_log(log_path: Path, provider: str = "codex") -> tuple[int, int, float]:
    """Dispatch to the right cost parser based on provider."""
    if provider == "opencode":
        return parse_opencode_cost_from_log(log_path)
    if provider == "codex":
        return parse_codex_cost_from_log(log_path)
    # Claude has no cost parser yet; return zeros (the runner still
    # records iterations / outcomes even without token telemetry).
    return (0, 0, 0.0)


def summarize_run(log_jsonl: Path, agent_log: Path,
                  provider: str = "codex") -> dict:
    """Per-rep summary, derived from orchestrator-emitted run_summary.json.

    The orchestrator writes cores/<target>/experiments/run_summary.json
    after every round and at end of main(), so a finalized rep dir always
    has it. summarize_run loads that file and folds in provider-specific
    token/cost counts from agent.log.

    If run_summary.json is absent or unreadable (orchestrator crashed
    before writing the first one, or pre-Phase-2 orchestrator), the row
    notes the missing summary so the leaderboard can flag the rep as
    not-summarizable rather than silently scoring 0/0/0.
    """
    toks_in, toks_out, cost = parse_cost_from_log(agent_log, provider=provider)
    summary_path = log_jsonl.parent / "run_summary.json"

    s: dict | None = None
    if summary_path.is_file():
        try:
            s = json.loads(summary_path.read_text())
        except (json.JSONDecodeError, OSError):
            s = None

    if not isinstance(s, dict):
        return {
            "iterations": 0,
            "accepted": 0,
            "rejected": 0,
            "broken": 0,
            "broken_by_class": {},
            "final_fitness": None,
            "baseline_fitness": None,
            "best_fitness": None,
            "best_round": None,
            "delta_pct": None,
            "best_lut4": None,
            "best_ff": None,
            "best_fmax_mhz": None,
            "best_iterations": None,
            "best_cycles": None,
            "best_ipc_coremark": None,
            "total_tokens_in": toks_in,
            "total_tokens_out": toks_out,
            "total_cost_usd": cost,
            "summary_missing": True,
        }

    return {
        "iterations":      int(s.get("iterations", 0) or 0),
        "accepted":        int(s.get("accepted", 0) or 0),
        "rejected":        int(s.get("rejected", 0) or 0),
        "broken":          int(s.get("broken", 0) or 0),
        "broken_by_class": dict(s.get("broken_by_class") or {}),
        "final_fitness":   s.get("final_fitness"),
        "baseline_fitness":s.get("baseline_fitness"),
        "best_fitness":    s.get("best_fitness"),
        "best_round":      s.get("best_round"),
        "delta_pct":       s.get("delta_pct"),
        "best_lut4":         s.get("best_lut4"),
        "best_ff":           s.get("best_ff"),
        "best_fmax_mhz":     s.get("best_fmax_mhz"),
        "best_iterations":   s.get("best_iterations"),
        "best_cycles":       s.get("best_cycles"),
        "best_ipc_coremark": s.get("best_ipc_coremark"),
        "total_tokens_in": toks_in,
        "total_tokens_out":toks_out,
        "total_cost_usd":  cost,
    }
