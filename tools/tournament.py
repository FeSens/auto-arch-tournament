"""Speculative-tournament orchestration helpers.

The orchestrator delegates to this module for per-round logic so the pure
helpers (ID allocation, diversity rotation, winner picking) can be unit
tested without claude or the FPGA toolchain.
"""
from __future__ import annotations

import contextlib
import datetime
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional


# Cap on the RTL diff carried alongside a slot's log entry into the scribe.
# A 30 KB rewrite-everything diff is no more lesson-bearing than an 8 KB
# excerpt; the trim is a token-budget control, not a signal control.
_SLOT_DIFF_MAX_CHARS = 8000


def _capture_slot_diff(worktree: str, target: str, base_branch: str = "main",
                       max_chars: int = _SLOT_DIFF_MAX_CHARS) -> str:
    """Capture the implementing agent's RTL changes vs. the round's base branch.

    Called by run_slot at each return path *before* the worktree is destroyed
    (the coordinator destroys losing-slot worktrees after run_slot returns,
    by which point the diff would be unrecoverable). The diff is stashed on
    the entry under `_diff` and consumed by the scribe in append_log; the
    underscore prefix marks it for stripping before the JSONL write.

    Returns "" on any error (missing worktree, git failure, target=None) so
    a slot that never created a worktree (hypothesis-gen failed, schema
    failed) still gets a clean entry.
    """
    if not target:
        return ""
    if not Path(worktree).exists():
        return ""
    try:
        out = subprocess.run(
            ["git", "-C", worktree, "diff", base_branch, "--",
             f"cores/{target}/rtl/"],
            capture_output=True, text=True, check=True,
        ).stdout
    except subprocess.CalledProcessError:
        return ""
    if len(out) > max_chars:
        out = out[:max_chars] + "\n[... diff truncated ...]\n"
    return out

# The hypothesis schema's `category` enum, in the order the brief specifies.
# Slot index modulo len(CATEGORIES) picks one — slot 5+ wraps. This keeps
# round diversity deterministic while still letting the agent pick a
# different angle for each slot.
CATEGORIES: list[str] = [
    "micro_opt",
    "structural",
    "predictor",
    "memory",
    "extension",
]


def category_for_slot(slot: int) -> str:
    """Return the diversity category for a slot index, wrapping at 5."""
    return CATEGORIES[slot % len(CATEGORIES)]


def allocate_round_ids(
    round_id: int,
    tournament_size: int,
    today: Optional[str] = None,
    first_seq: int = 1,
) -> list[str]:
    """Pre-allocate `tournament_size` hypothesis IDs for a round.

    IDs follow `hyp-YYYYMMDD-NNN-rRsS` so they're unique across slots
    AND back-compat with the legacy `hyp-YYYYMMDD-NNN` shape (the
    schema regex now accepts both). Pre-allocation is the fix for the
    `_next_id` race: two slots calling it concurrently would otherwise
    pick the same NNN.
    """
    if today is None:
        today = datetime.date.today().strftime("%Y%m%d")
    return [
        f"hyp-{today}-{(first_seq + s):03d}-r{round_id}s{s}"
        for s in range(tournament_size)
    ]


def pick_winner(entries: list[dict],
                current_best: float,
                current_lut: float | None = None,
                coremark_target: float | None = None,
                lut_target: float | None = None) -> Optional[dict]:
    """Return the round's winner via the accept-rule module.

    With no targets set, behavior is identical to the legacy "highest
    fitness > current_best" rule. With targets set, accept() is called
    per-candidate with (perf, lut) tuples.

    Tie-break: among candidates that all pass accept, prefer the one
    that maximizes (fitness, -lut4, -slot). This degenerates to the
    legacy "highest fitness, lowest slot" tie-break when LUT is
    unconstrained.
    """
    from tools.accept_rule import accept

    valid = [e for e in entries
             if isinstance(e.get("fitness"), (int, float))]
    if not valid:
        return None

    old = (current_best, current_lut)

    candidates = []
    for e in valid:
        new = (e["fitness"], e.get("lut4"))
        if accept(old, new,
                  coremark_target=coremark_target, lut_target=lut_target):
            candidates.append(e)

    if not candidates:
        return None
    return max(candidates,
               key=lambda e: (e["fitness"], -(e.get("lut4") or 0), -e["slot"]))


# Per-phase capacity. Two distinct reasons phases are gated:
#
# - formal=1 is a CORRECTNESS INVARIANT, not a CPU gate. formal/run_all.sh
#   stages rtl/*.sv into formal/riscv-formal/cores/auto-arch-researcher/,
#   which lives in the MAIN repo (the worktree's formal/riscv-formal is a
#   symlink). Two slots running formal concurrently would corrupt that
#   shared staging area. NEVER loosen this gate above 1.
#
# - fpga=1 is a CPU saturation gate. Each slot's run_fpga_eval already
#   forks 3 parallel nextpnr seeds; N slots × 3 seeds at once would thrash
#   on most hardware. Loosening it is a perf trade-off, not a correctness
#   risk.
#
# Phase 3 (lint/synth/build) and Phase 5 (cosim) are not gated: each
# worktree has its own generated/ + bench/programs/*.elf + obj_dir/, so no
# shared-state risk; with N=3 they may CPU-thrash but the round still
# completes correctly.
PHASE_CAPACITY: dict[str, int] = {
    "formal": 1,
    "fpga":   1,
}

# Module-level semaphores so all slots in a process share the same gates.
# Created lazily so test imports don't allocate them up front.
_phase_semaphores: dict[str, threading.Semaphore] = {}
_phase_semaphores_lock = threading.Lock()


def _get_phase_sem(phase: str) -> threading.Semaphore:
    with _phase_semaphores_lock:
        sem = _phase_semaphores.get(phase)
        if sem is None:
            sem = threading.Semaphore(PHASE_CAPACITY.get(phase, 1))
            _phase_semaphores[phase] = sem
        return sem


@contextlib.contextmanager
def phase_gate(phase: str):
    """Acquire the named phase's capacity semaphore. Use as `with phase_gate('formal'):`.
    A phase not in PHASE_CAPACITY defaults to capacity=1 (conservative)."""
    sem = _get_phase_sem(phase)
    sem.acquire()
    try:
        yield
    finally:
        sem.release()


def run_slot(
    slot: int,
    hyp_id: str,
    allowed_yaml_ids: list[str],
    log_tail: list,
    current_best: float,
    current_lut: float | None,
    baseline: float,
    fixed_hyp_path: str | None,
    targets: dict | None,
    target_branch: str = "main",
    target: str | None = None,
    patterns: tuple = (),
) -> dict:
    """Run one tournament slot end-to-end. Returns a draft log entry.

    The entry has `outcome` set provisionally:
      - 'broken' / 'placement_failed' if any gate failed
      - 'regression' if all gates passed (winner-pick may upgrade to 'improvement')
    The coordinator decides the final outcome after all slots finish.

    Args:
      slot            -- slot index within the round.
      hyp_id          -- pre-allocated hypothesis ID string.
      allowed_yaml_ids -- full set of IDs allocated for this round.
      log_tail        -- recent experiment log entries.
      current_best    -- best fitness seen so far on the branch.
      current_lut     -- best LUT4 count seen so far, or None.
      baseline        -- fitness of the unmodified baseline.
      fixed_hyp_path  -- if set, skip hypothesis generation and use this YAML.
      targets         -- optional {coremark, lut} performance targets.
      target_branch   -- git branch to merge accepted worktrees into.
      target          -- core name under cores/. When None, uses legacy rtl/ paths.
      patterns        -- pre-built sandbox allow patterns for this target.
    """
    # Lazy imports to avoid circular import with tools.orchestrator.
    import yaml
    import jsonschema
    from tools.orchestrator import (
        emit_verilog, offlimits_changes, _read_notes, validate_hypothesis,
    )
    from tools.worktree import create_worktree, destroy_worktree
    from tools.agents.hypothesis import run_hypothesis_agent
    from tools.agents.implement import run_implementation_agent
    from tools.eval.formal import run_formal
    from tools.eval.cosim import run_cosim
    from tools.eval.fpga import run_fpga_eval

    category = category_for_slot(slot)
    print(f"  [slot {slot}] category={category} id={hyp_id}", flush=True)

    # Phase 1: hypothesis.
    if fixed_hyp_path:
        hyp_path = fixed_hyp_path
    else:
        try:
            current_state = (
                {"coremark": current_best, "lut": current_lut}
                if (targets and current_best > 0) else None
            )
            hyp_path = run_hypothesis_agent(
                log_tail, current_best, baseline,
                hyp_id=hyp_id,
                allowed_yaml_ids=allowed_yaml_ids,
                category_hint=category,
                targets=targets,
                current_state=current_state,
                target=target,
            )
        except Exception as e:
            return {
                'id': hyp_id, 'title': f'(slot {slot} hypothesis-gen failed)',
                'category': category, 'outcome': 'broken',
                'formal_passed': False, 'cosim_passed': False,
                'error': f'hypothesis_gen_failed: {e}',
                'slot': slot,
            }

    # Phase 1b: schema validation.
    try:
        hyp = validate_hypothesis(hyp_path)
    except (jsonschema.ValidationError, FileNotFoundError, yaml.YAMLError) as e:
        return {
            'id': hyp_id, 'title': str(hyp_path), 'category': category,
            'outcome': 'broken', 'formal_passed': False, 'cosim_passed': False,
            'error': f'schema_error: {e}',
            'slot': slot,
        }

    # Phase 2: implement.
    worktree_id = hyp['id']  # could differ from hyp_id if agent ignored override
    worktree = create_worktree(worktree_id, base_branch=target_branch, target=target)
    print(f"  [slot {slot}] worktree={worktree}", flush=True)

    def broken(reason: str, detail: str = '') -> dict:
        # Capture the agent's RTL diff before destroy — the scribe needs it,
        # and once the worktree is gone the diff is unrecoverable.
        diff = _capture_slot_diff(worktree, target, target_branch)
        destroy_worktree(worktree_id, target=target)
        return {
            **hyp, 'outcome': 'broken', 'formal_passed': False,
            'cosim_passed': False, 'error': f'{reason}: {detail}',
            'slot': slot,
            '_diff': diff,
        }

    if fixed_hyp_path and hyp.get('skip_implementation'):
        pass  # baseline-retest fixture path
    else:
        impl_ok = run_implementation_agent(hyp_path, worktree, target=target)
        if not impl_ok:
            return broken("implementation_compile_failed")

    sandbox_breaches = offlimits_changes(worktree, patterns)
    if sandbox_breaches:
        return broken("sandbox_violation",
                      f"agent touched off-limits paths: {sandbox_breaches}")

    # Phase 3: lint + synth + bench + cosim-build (no gate; fast).
    build_ok, build_reason = emit_verilog(worktree, target=target)
    if not build_ok:
        return broken("build_failed", build_reason)

    # Phase 4: formal (gated, formal=1).
    with phase_gate('formal'):
        formal = run_formal(worktree, target=target)
    if not formal['passed']:
        check  = formal.get('failed_check', '')
        detail = formal.get('detail', '')
        msg    = f"{check}\n{detail}".strip() if detail else check
        return broken("formal_failed", msg)

    # Phase 5: cosim (no gate).
    cosim = run_cosim(worktree, target=target)
    if not cosim['passed']:
        return broken("cosim_failed", cosim.get('failed_elf', ''))

    # Phase 6: FPGA (gated, fpga=1).
    with phase_gate('fpga'):
        fpga = run_fpga_eval(worktree, target=target)
    if fpga.get('placement_failed'):
        return {
            **hyp, 'outcome': 'placement_failed', 'formal_passed': True,
            'cosim_passed': True, 'error': 'placement_failed',
            'seeds': fpga.get('seeds'),
            'slot': slot,
            '_diff': _capture_slot_diff(worktree, target, target_branch),
        }
    if fpga.get('bench_failed'):
        return broken("coremark_failed", fpga.get('reason', ''))

    fitness = fpga['fitness']
    delta   = ((fitness - current_best) / current_best * 100) if current_best > 0 else 0.0
    vs_base = ((fitness - baseline) / baseline * 100) if baseline > 0 else 0.0

    return {
        **hyp,
        # Provisional. Coordinator upgrades winner to 'improvement'.
        'outcome':       'regression',
        'fitness':       fitness,
        'delta_pct':     round(delta, 2),
        'vs_baseline':   round(vs_base, 2),
        'fmax_mhz':      fpga['fmax_mhz'],
        'ipc_coremark':  fpga['ipc_coremark'],
        'cycles':        fpga.get('cycles'),
        'iterations':    fpga.get('iterations'),
        'lut4':          fpga['lut4'],
        'ff':            fpga['ff'],
        'seeds':         fpga['seeds'],
        'formal_passed': True,
        'cosim_passed':  True,
        'error':         None,
        'implementation_notes': _read_notes(worktree),
        'timestamp':     datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        'slot':          slot,
        '_diff':         _capture_slot_diff(worktree, target, target_branch),
    }


def run_tournament_round(
    round_id: int,
    tournament_size: int,
    log: list,
    fixed_hyp_paths: list[str] | None = None,
    targets: dict | None = None,
    target_branch: str = "main",
    target: str | None = None,
) -> list[dict]:
    """Run one round of N slots in parallel; return list of log entries.

    All Phase 1+2 work (hypothesis + implement) runs concurrently across
    slots. Phase 4 (formal) and Phase 6 (fpga) are serialized via
    `phase_gate` semaphores. After all slots return, the coordinator runs
    winner-pick + accept/destroy + append_log SEQUENTIALLY — no parallel
    git-index mutation, by design.

    Args:
      round_id        -- monotonically increasing round number.
      tournament_size -- number of parallel slots in this round (N).
      log             -- list of log entries from prior rounds (read-only).
      fixed_hyp_paths -- if set, skip LLM hypothesis gen and use these YAMLs
                         (one per slot; length must equal tournament_size).
      targets         -- optional {coremark, lut} performance targets dict.
      target_branch   -- git branch to merge winning worktrees into.
      target          -- core name under cores/. When None, uses legacy rtl/ paths.
    """
    assert target is not None, "run_tournament_round requires target (orchestrator's CLI guards this)"
    from tools.orchestrator import (
        current_best as _current_best,
        current_lut as _current_lut,
        baseline_fitness as _baseline,
        append_log,
        allowed_patterns_for,
    )
    from tools.worktree import accept_worktree, destroy_worktree

    best     = _current_best(log)
    cur_lut  = _current_lut(log)
    baseline = _baseline(log)
    print(f"\n{'='*60}\nRound {round_id}  |  slots={tournament_size}  |  current best={best:.2f}\n{'='*60}", flush=True)

    # Build per-target sandbox patterns once for the whole round.
    patterns = allowed_patterns_for(target) if target else ()

    today = datetime.date.today().strftime("%Y%m%d")
    # First-seq picker: continue numbering from existing files in
    # cores/<target>/experiments/hypotheses/ for the day so IDs stay
    # monotonic across rounds within a single day. _next_id-style logic,
    # hoisted up.
    from tools.agents.hypothesis import hypotheses_dir as _hypotheses_dir
    hyp_dir = _hypotheses_dir(target)
    hyp_dir.mkdir(parents=True, exist_ok=True)
    existing = list(hyp_dir.glob(f"hyp-{today}-*.yaml"))
    first_seq = len(existing) + 1
    hyp_ids = allocate_round_ids(round_id, tournament_size, today=today,
                                 first_seq=first_seq)
    print(f"  pre-allocated IDs: {hyp_ids}", flush=True)

    # Validate fixed_hyp_paths shape.
    if fixed_hyp_paths is not None:
        if len(fixed_hyp_paths) != tournament_size:
            raise ValueError(
                f"--from-hypothesis count {len(fixed_hyp_paths)} != tournament_size {tournament_size}"
            )
    else:
        fixed_hyp_paths = [None] * tournament_size

    # Fan out N slots in parallel (agent calls + worktree builds).
    entries: list[dict] = []
    with ThreadPoolExecutor(max_workers=tournament_size) as pool:
        futures = {
            pool.submit(
                run_slot, slot, hyp_ids[slot], hyp_ids,
                log, best, cur_lut, baseline, fixed_hyp_paths[slot],
                targets, target_branch, target, patterns,
            ): slot
            for slot in range(tournament_size)
        }
        for fut in as_completed(futures):
            entry = fut.result()
            entry['round_id'] = round_id
            entries.append(entry)
            print(f"  [slot {entry['slot']}] returned outcome={entry['outcome']}", flush=True)

    # Sort by slot for stable log ordering (aesthetic, helps grep).
    entries.sort(key=lambda e: e['slot'])

    # Winner pick: highest-fitness slot whose fitness > start-of-round best.
    winner = pick_winner(
        entries,
        current_best=best,
        current_lut=cur_lut,
        coremark_target=(targets or {}).get("coremark"),
        lut_target=(targets or {}).get("lut"),
    )

    # Apply outcomes + accept/destroy worktrees. Sequential — the coordinator
    # thread is the ONLY thread mutating main-repo git state from here on.
    for entry in entries:
        if entry is winner:
            entry['outcome'] = 'improvement'
            msg = (f"{entry['id']}: {entry['title']} "
                   f"(+{entry.get('delta_pct', 0):.1f}%)")
            try:
                accept_worktree(entry['id'], msg, target_branch=target_branch, target=target)
            except Exception as e:
                # Worktree merge failed (shouldn't happen with ff-only on a
                # single-coordinator process). Downgrade to regression so the
                # log still lands, and best-effort cleanup so we don't leak
                # the branch + worktree dir. The agent's RTL commit on that
                # branch is intentionally abandoned — losing one slot's work
                # is preferable to leaving a stale branch that confuses the
                # next round's `git worktree list`.
                print(f"  [coordinator] accept_worktree({entry['id']}) failed: {e}",
                      flush=True)
                entry['outcome'] = 'regression'
                try:
                    destroy_worktree(entry['id'], target=target)
                except Exception as cleanup_err:
                    print(f"  [coordinator] cleanup also failed: {cleanup_err}",
                          flush=True)
        elif entry.get('fitness') is not None and entry['outcome'] == 'regression':
            destroy_worktree(entry['id'], target=target)
        # 'broken' / 'placement_failed' slots already destroyed their worktree.

    # Append log entries one-by-one through the lock-serialized append_log.
    for entry in entries:
        append_log(entry)

    print(f"\n  Round {round_id} complete: " +
          ", ".join(f"slot {e['slot']}={e['outcome']}" for e in entries) +
          (f" (winner: slot {winner['slot']})" if winner else " (no winner)"),
          flush=True)
    return entries
