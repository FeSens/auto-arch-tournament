#!/usr/bin/env python3
"""Hardcoded AutoResearch loop. The LLM never touches this file."""
import argparse, json, datetime, subprocess, re, threading
from pathlib import Path

import jsonschema, yaml

from tools.worktree import create_worktree, accept_worktree, destroy_worktree
from tools.agents.hypothesis import run_hypothesis_agent
from tools.agents.implement import run_implementation_agent
from tools.eval.formal import run_formal
from tools.eval.cosim import run_cosim
from tools.eval.fpga import run_fpga_eval
from tools.plot import plot_progress
from tools.tournament import run_tournament_round

LOG_PATH      = Path("experiments/log.jsonl")
HYP_SCHEMA    = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA = json.loads(Path("schemas/eval_result.schema.json").read_text())

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

def current_best(log: list) -> float:
    improvements = [e['fitness'] for e in log if e.get('outcome') == 'improvement']
    return max(improvements) if improvements else 0.0

def baseline_fitness(log: list) -> float:
    if log: return log[0].get('fitness', 0.0)
    return 0.0

def append_log(entry: dict):
    with _LOG_LOCK:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open('a') as f:
            f.write(json.dumps(entry) + '\n')
        # Regen progress.png from the updated log so the README chart reflects
        # every iteration (improvement, regression, broken — see plot.py's
        # color_map). plot_progress reads LOG_PATH directly, so this picks up
        # the line we just appended.
        plot_progress()
        # Commit log + plot together. One "log: <id> <outcome>" commit per
        # iteration; for accepts this lands alongside the implementation
        # merge that accept_worktree already created.
        subprocess.run(["git", "add", str(LOG_PATH)], check=True)
        plot_path = Path("experiments/progress.png")
        if plot_path.exists():
            subprocess.run(["git", "add", str(plot_path)], check=True)
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

def emit_verilog(worktree: str) -> bool:
    """Prepare a worktree for evaluation.

    SV-source-of-truth project: there is no Chisel emit step. Instead this
    function (1) lints rtl/*.sv with verilator, (2) synthesizes core_bench
    via yosys for nextpnr, (3) builds the bench ELFs (selftest + coremark),
    and (4) rebuilds the Verilator cosim binary against the worktree's
    rtl/*.sv. Any failure here is a "broken" outcome — the hypothesis
    didn't even compile.
    """
    worktree = str(Path(worktree).resolve())

    # 1. Verilator lint over rtl/. Catches syntax errors before slower steps.
    lint = subprocess.run(
        ["bash", "-lc",
         "if ls rtl/*.sv >/dev/null 2>&1; then "
         "verilator --lint-only -Wall -Wno-MULTITOP -sv rtl/*.sv; "
         "else echo 'lint: no source files in rtl/'; exit 1; fi"],
        cwd=worktree, capture_output=True,
    )
    if lint.returncode != 0:
        return False

    # 2. Yosys synth (writes generated/synth.json for nextpnr).
    Path(worktree, "generated").mkdir(exist_ok=True)
    synth = subprocess.run(
        ["yosys", "-c", "fpga/scripts/synth.tcl"],
        cwd=worktree, capture_output=True,
    )
    if synth.returncode != 0:
        return False

    # 3. Build bench ELFs (selftest + coremark). They are gitignored.
    bench = subprocess.run(
        ["make", "-f", "bench/programs/Makefile", "all"],
        cwd=worktree, capture_output=True,
    )
    if bench.returncode != 0:
        return False

    # 4. Rebuild Verilator cosim binary against the worktree's RTL.
    build = subprocess.run(
        ["bash", "test/cosim/build.sh"],
        cwd=worktree, capture_output=True,
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
    args = parser.parse_args()

    if args.report:
        run_report()
        return

    fixed = None
    if args.from_hypothesis:
        fixed = [p.strip() for p in args.from_hypothesis.split(',')]

    # Round numbering: continue from the highest round_id in the log + 1
    # so multiple `make next` invocations don't all label themselves round 1.
    log = read_log()
    prior_rounds = [e.get('round_id', 0) for e in log if isinstance(e.get('round_id'), int)]
    next_round = (max(prior_rounds) + 1) if prior_rounds else 1

    for r in range(args.iterations):
        round_id = next_round + r
        log = read_log()
        run_tournament_round(round_id, args.tournament_size, log,
                             fixed_hyp_paths=fixed)

if __name__ == '__main__':
    main()
