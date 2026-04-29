#!/usr/bin/env python3
"""Hardcoded AutoResearch loop. The LLM never touches this file."""
import argparse, json, datetime, os, subprocess, re, threading, sys
from pathlib import Path

import jsonschema, yaml

# Disable commit/tag signing for every git subprocess in the orchestrator
# process tree. With SSH-key signing + a 1Password agent, every
# administrative commit (worktree accept, log+plot append) prompts for
# biometric auth, which hangs the loop when running unattended.
# Affects only orchestrator-spawned git calls; manual `git commit`
# from a shell still signs normally.
_SIGN_OFF = "'commit.gpgsign=false' 'tag.gpgsign=false'"
os.environ["GIT_CONFIG_PARAMETERS"] = (
    (os.environ.get("GIT_CONFIG_PARAMETERS", "").strip() + " " + _SIGN_OFF).strip()
)

from tools.worktree import create_worktree, accept_worktree, destroy_worktree
from tools.agents.hypothesis import run_hypothesis_agent
from tools.agents.implement import run_implementation_agent
from tools.eval.formal import run_formal
from tools.eval.cosim import run_cosim
from tools.eval.fpga import run_fpga_eval
from tools.plot import plot_progress
from tools.tournament import run_tournament_round

# When orchestrator is launched via `python3 -m tools.orchestrator`, Python
# only registers it under `__main__`, not `tools.orchestrator`. Sub-modules
# (e.g., tools.tournament's lazy imports of current_lut/current_best) then
# trigger a fresh disk read of tools/orchestrator.py — which is fatal when
# git checkout has swapped the on-disk file to an older baseline-tag
# version. Register the running module under the dotted name so dotted
# imports always resolve to the in-memory copy.
sys.modules.setdefault('tools.orchestrator', sys.modules[__name__])

# Pre-import sub-modules that are imported lazily elsewhere (e.g.,
# tools.tournament's `from tools.accept_rule import accept` inside
# pick_winner). This forces them into sys.modules at orchestrator
# startup, so any later git checkout that removes the on-disk file
# (e.g., when forking a branch from a tag predating the file's commit)
# doesn't break the lazy import.
import tools.accept_rule  # noqa: F401

LOG_PATH       = Path("experiments/log.jsonl")
PLOT_PATH      = Path("experiments/progress.png")
HYP_SCHEMA     = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA  = json.loads(Path("schemas/eval_result.schema.json").read_text())

# Serializes append_log across concurrent tournament slots. The body of
# append_log writes log.jsonl, regenerates progress.png, then git-adds
# and commits both — three operations that all touch the index. Without
# this lock, two slots finishing within the same ~second would race on
# .git/index.lock and crash the round.
_LOG_LOCK = threading.Lock()

# Don't-touch sandbox: anything outside ALLOWED_PATTERNS that the agent
# touches is rejected before the eval gates run. Without this an agent
# could silently soften checks.cfg, the cosim main.cpp, or the
# fpga.py CRC table and inflate its own fitness score.
#
# Permitted modifications, per CLAUDE.md "What hypotheses MAY change":
#   - rtl/ (any file)
#   - test/test_*.py (cocotb suites for new modules)
#   - implementation_notes.md (the agent's own writeup, untracked)
#
# Everything else is off-limits.
ALLOWED_PATTERNS = (
    re.compile(r"^rtl/.+"),
    re.compile(r"^test/test_[^/]+\.py$"),
    re.compile(r"^implementation_notes\.md$"),
)


def path_is_allowed(path: str) -> bool:
    return any(p.match(path) for p in ALLOWED_PATTERNS)


def offlimits_changes(worktree: str) -> list:
    """Return paths the agent modified that are NOT on the allow list.

    Reads `git status --porcelain` against the worktree's HEAD. Catches
    modifications, deletions, additions, and renames. Returns [] if the
    sandbox is clean.
    """
    out = subprocess.run(
        ["git", "-C", str(worktree), "status", "--porcelain"],
        capture_output=True, text=True, check=True,
    ).stdout
    bad = []
    for line in out.splitlines():
        if not line:
            continue
        # porcelain format: 2-char status + space + path. For renames the
        # path is "OLD -> NEW"; flag both ends.
        rest = line[3:]
        for p in (s.strip() for s in rest.split(" -> ")):
            if p and not path_is_allowed(p):
                bad.append(p)
    return bad

def read_log() -> list:
    if not LOG_PATH.exists(): return []
    return [json.loads(l) for l in LOG_PATH.read_text().splitlines() if l.strip()]

def _last_improvement(log: list) -> dict | None:
    """The most recent accepted-improvement entry, or None.

    Both current_best() and current_lut() anchor on this so that in dual-
    target Pareto mode (where accept() can take a lower-fitness entry to
    improve the combined score) the comparison anchor is a real design,
    not a (max-fitness, last-lut4) phantom.
    """
    improvements = [e for e in log if e.get('outcome') == 'improvement']
    return improvements[-1] if improvements else None


def current_best(log: list) -> float:
    """Fitness of the running champion (most recent accepted improvement).

    In no-targets mode, accept is monotonic on fitness so this is also
    max(fitness). In Pareto mode, lower-fitness improvements that win on
    score can land, and the champion is whichever entry came last.
    """
    last = _last_improvement(log)
    if last is None:
        return 0.0
    val = last.get('fitness')
    return float(val) if isinstance(val, (int, float)) else 0.0


def baseline_fitness(log: list) -> float:
    if log: return log[0].get('fitness', 0.0)
    return 0.0


def current_lut(log: list) -> float | None:
    """LUT4 of the running champion (most recent accepted improvement)."""
    last = _last_improvement(log)
    if last is None:
        return None
    val = last.get('lut4')
    return val if isinstance(val, (int, float)) else None

def append_log(entry: dict):
    with _LOG_LOCK:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open('a') as f:
            f.write(json.dumps(entry) + '\n')
        # Regen progress.png from the updated log so the README chart reflects
        # every iteration (improvement, regression, broken — see plot.py's
        # color_map). plot_progress reads LOG_PATH directly, so this picks up
        # the line we just appended.
        plot_progress(log_path=LOG_PATH, out_path=PLOT_PATH)
        # Commit log + plot together. One "log: <id> <outcome>" commit per
        # iteration; for accepts this lands alongside the implementation
        # merge that accept_worktree already created.
        subprocess.run(["git", "add", str(LOG_PATH)], check=True)
        if PLOT_PATH.exists():
            subprocess.run(["git", "add", str(PLOT_PATH)], check=True)
        subprocess.run(
            ["git", "commit", "-m",
             f"log: {entry.get('id','unknown')} {entry.get('outcome','unknown')}"],
            check=True,
        )

def validate_hypothesis(hyp_path: str) -> dict:
    with open(hyp_path) as f:
        hyp = yaml.safe_load(f)
    jsonschema.validate(hyp, HYP_SCHEMA)
    return hyp

def emit_verilog(worktree: str, target: str | None = None) -> bool:
    """Prepare a worktree for evaluation.

    SV-source-of-truth project: there is no Chisel emit step. Instead this
    function (1) lints rtl/*.sv with verilator, (2) synthesizes core_bench
    via yosys for nextpnr, (3) builds the bench ELFs (selftest + coremark),
    and (4) rebuilds the Verilator cosim binary against the worktree's
    rtl/*.sv. Any failure here is a "broken" outcome — the hypothesis
    didn't even compile.

    Args:
      worktree -- absolute path to the worktree directory.
      target   -- core name under cores/. When set, RTL lives in
                  cores/<target>/rtl/ instead of rtl/.
    """
    worktree = str(Path(worktree).resolve())

    # 1. Verilator lint. Catches syntax errors before slower steps.
    if target:
        rtl_glob = f"cores/{target}/rtl/*.sv"
        lint_cmd = (
            f"if ls {rtl_glob} >/dev/null 2>&1; then "
            f"verilator --lint-only -Wall -Wno-MULTITOP -sv {rtl_glob}; "
            f"else echo 'lint: no source files in {rtl_glob}'; exit 1; fi"
        )
    else:
        lint_cmd = (
            "if ls rtl/*.sv >/dev/null 2>&1; then "
            "verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; "
            "else echo 'lint: no source files in rtl/'; exit 1; fi"
        )
    lint = subprocess.run(
        ["bash", "-lc", lint_cmd],
        cwd=worktree, capture_output=True,
    )
    if lint.returncode != 0:
        return False

    # 2. Yosys synth (writes generated/synth.json for nextpnr).
    Path(worktree, "generated").mkdir(exist_ok=True)
    synth_env = {**os.environ, "RTL_DIR": f"cores/{target}/rtl"} if target else None
    synth = subprocess.run(
        ["yosys", "-c", "fpga/scripts/synth.tcl"],
        cwd=worktree, capture_output=True,
        env=synth_env,
    )
    if synth.returncode != 0:
        return False

    # 3. Build bench ELFs (selftest + coremark). They are gitignored.
    # Bench programs are shared across cores; no target-specific env needed.
    bench = subprocess.run(
        ["make", "-f", "bench/programs/Makefile", "all"],
        cwd=worktree, capture_output=True,
    )
    if bench.returncode != 0:
        return False

    # 4. Rebuild Verilator cosim binary against the worktree's RTL.
    build_env = (
        {**os.environ,
         "RTL_DIR": f"cores/{target}/rtl",
         "OBJ_DIR": f"cores/{target}/obj_dir"}
        if target else None
    )
    build = subprocess.run(
        ["bash", "test/cosim/build.sh"],
        cwd=worktree, capture_output=True,
        env=build_env,
    )
    return build.returncode == 0

def _read_notes(worktree: str) -> str:
    p = Path(worktree) / "implementation_notes.md"
    return p.read_text() if p.exists() else ""

def run_report():
    log = read_log()
    if not log:
        print("No experiments yet.")
        return
    improvements = [e for e in log if e.get('outcome') == 'improvement']
    broken       = [e for e in log if e.get('outcome') == 'broken']
    regressions  = [e for e in log if e.get('outcome') == 'regression']
    print(f"\nExperiment Report")
    print(f"  Total iterations : {len(log)}")
    print(f"  Improvements     : {len(improvements)}")
    print(f"  Regressions      : {len(regressions)}")
    print(f"  Broken           : {len(broken)}")
    if improvements:
        best = max(improvements, key=lambda e: e['fitness'])
        print(f"  Best fitness     : {best['fitness']:.2f}  ({best['title']})")
    print(f"\nChampion path:")
    for e in improvements:
        print(f"  {e['id']:20s}  {e['fitness']:6.2f}  ({e['delta_pct']:+.1f}%)  {e['title']}")

def _resolve_ref(ref: str) -> str:
    """git rev-parse <ref> -> SHA, or raise SystemExit with a clear message."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--verify", ref],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except subprocess.CalledProcessError:
        raise SystemExit(f"baseline: cannot resolve git ref '{ref}'.")


def _branch_exists(name: str) -> bool:
    return subprocess.run(
        ["git", "rev-parse", "--verify", f"refs/heads/{name}"],
        capture_output=True,
    ).returncode == 0


def _ensure_branch(branch: str, baseline: str | None) -> bool:
    """Create branch from baseline (or main) if missing; error if both branch
    and baseline are set and the branch already exists. Returns True iff the
    branch was newly created (caller uses this to decide whether to run a
    baseline retest)."""
    exists = _branch_exists(branch)
    if exists and baseline is not None:
        raise SystemExit(
            f"Branch '{branch}' already exists. To start fresh from "
            f"'{baseline}', run `git branch -D {branch}` first."
        )
    if not exists:
        ref = baseline or "main"
        sha = _resolve_ref(ref)
        subprocess.run(["git", "branch", branch, sha], check=True)
        return True
    return False


def _run_baseline_retest(branch: str, target: str | None = None):
    """Run a one-shot eval on the freshly created branch's RTL.

    Writes a single 'baseline' entry to the per-branch log so subsequent
    hypothesis rounds have a fitness anchor. Aborts the run if any gate
    fails — the user investigates while the branch is left intact.

    Args:
      branch -- name of the branch being retested.
      target -- core name under cores/. When None, uses legacy rtl/ paths.
    """
    # Re-emit verilog + run gates against the main repo's working copy
    # (the active branch is checked out). We don't create a worktree —
    # the baseline retest IS the branch tip, not a hypothesis.
    repo_root = str(Path(".").resolve())
    if not emit_verilog(repo_root, target=target):
        raise SystemExit(f"baseline retest: emit_verilog failed on '{branch}'.")
    formal = run_formal(repo_root, target=target)
    if not formal['passed']:
        raise SystemExit(
            f"baseline retest: formal failed on '{branch}': "
            f"{formal.get('failed_check','')}"
        )
    cosim = run_cosim(repo_root, target=target)
    if not cosim['passed']:
        raise SystemExit(
            f"baseline retest: cosim failed on '{branch}': "
            f"{cosim.get('failed_elf','')}"
        )
    fpga = run_fpga_eval(repo_root, target=target)
    if fpga.get('placement_failed') or fpga.get('bench_failed'):
        raise SystemExit(f"baseline retest: fpga eval failed on '{branch}'.")

    sha = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    entry = {
        'id':            f'baseline-{branch}-{sha}',
        'title':         f'Baseline retest for branch {branch}',
        'category':      'micro_opt',
        'outcome':       'improvement',
        'fitness':       fpga['fitness'],
        'delta_pct':     0.0,
        'vs_baseline':   0.0,
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
        'implementation_notes': '',
        'timestamp':     datetime.datetime.utcnow().isoformat(),
        'round_id':      0,
        'slot':          0,
    }
    append_log(entry)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--iterations', type=int, default=1,
                        help='Number of tournament rounds to run.')
    parser.add_argument('--tournament-size', type=int, default=3,
                        help='Number of parallel slots per round (N=1 = sequential).')
    parser.add_argument('--report', action='store_true')
    parser.add_argument('--from-hypothesis', metavar='PATH', default=None,
                        help='Skip the LLM hypothesis step and use a pre-written YAML. '
                             'Comma-separated list for tournament-size > 1.')
    parser.add_argument('--branch', default=None,
                        help='Sandbox merge target. Default: main.')
    parser.add_argument('--baseline', default=None,
                        help='Git ref for fresh-branch RTL fork. Default: main. '
                             'Requires --branch.')
    parser.add_argument('--coremark-target', type=int, default=None,
                        help='CoreMark iter/s target for two-phase Pareto accept.')
    parser.add_argument('--lut-target', type=int, default=None,
                        help='LUT4 target for two-phase Pareto accept.')
    parser.add_argument('--target', default=None,
                        help='Core name under cores/. If absent, uses legacy rtl/ paths.')
    args = parser.parse_args()

    # Flag validation.
    if args.baseline and not args.branch:
        raise SystemExit("--baseline requires --branch.")
    if args.coremark_target is not None and args.coremark_target <= 0:
        raise SystemExit("--coremark-target must be positive.")
    if args.lut_target is not None and args.lut_target <= 0:
        raise SystemExit("--lut-target must be positive.")

    # Per-branch log/plot. Must come before --report so a branch-scoped
    # report reads the per-branch log file. Default branch (no --branch)
    # keeps writing to experiments/log.jsonl + experiments/progress.png.
    target_branch = args.branch or "main"
    if args.branch:
        global LOG_PATH, PLOT_PATH
        LOG_PATH  = Path(f"experiments/log-{args.branch}.jsonl")
        PLOT_PATH = Path(f"experiments/progress-{args.branch}.png")

    if args.report:
        run_report()
        return

    targets = {}
    if args.coremark_target is not None:
        targets["coremark"] = args.coremark_target
    if args.lut_target is not None:
        targets["lut"] = args.lut_target

    # Branch lifecycle.
    fresh_branch = False
    if args.branch:
        fresh_branch = _ensure_branch(args.branch, args.baseline)
        subprocess.run(["git", "checkout", args.branch], check=True)

    # First-iteration baseline retest on fresh branches.
    if fresh_branch:
        print(f"[orchestrator] fresh branch '{args.branch}' — running baseline retest",
              flush=True)
        _run_baseline_retest(args.branch, target=args.target)

    fixed = None
    if args.from_hypothesis:
        fixed = [p.strip() for p in args.from_hypothesis.split(',')]

    # Round numbering.
    log = read_log()
    prior_rounds = [e.get('round_id', 0) for e in log if isinstance(e.get('round_id'), int)]
    next_round = (max(prior_rounds) + 1) if prior_rounds else 1

    for r in range(args.iterations):
        round_id = next_round + r
        log = read_log()
        run_tournament_round(
            round_id, args.tournament_size, log,
            fixed_hyp_paths=fixed,
            targets=targets or None,
            target_branch=target_branch,
            target=args.target,
        )

if __name__ == '__main__':
    main()
