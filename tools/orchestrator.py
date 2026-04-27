#!/usr/bin/env python3
"""Hardcoded AutoResearch loop. The LLM never touches this file."""
import argparse, json, datetime, subprocess, re
from pathlib import Path

import jsonschema, yaml

from tools.worktree import create_worktree, accept_worktree, destroy_worktree
from tools.agents.hypothesis import run_hypothesis_agent
from tools.agents.implement import run_implementation_agent
from tools.eval.formal import run_formal
from tools.eval.cosim import run_cosim
from tools.eval.fpga import run_fpga_eval
from tools.plot import plot_progress

LOG_PATH      = Path("experiments/log.jsonl")
HYP_SCHEMA    = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA = json.loads(Path("schemas/eval_result.schema.json").read_text())

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
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with LOG_PATH.open('a') as f:
        f.write(json.dumps(entry) + '\n')
    # Auto-commit so the log entry survives in git history. Without this,
    # rejected and broken iterations never produce an implementation
    # commit and the only record of them lives in an untracked file —
    # one `git clean -fdx` away from gone. README.md treats log.jsonl as
    # authoritative; this makes that real.
    subprocess.run(["git", "add", str(LOG_PATH)], check=True)
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

def run_iteration(iteration: int, log: list, fixed_hyp_path: str = None) -> dict:
    best = current_best(log)
    base = baseline_fitness(log)
    print(f"\n{'='*60}")
    print(f"Iteration {iteration}  |  Current best: {best:.2f}")
    print(f"{'='*60}")

    # 1. Hypothesis. If `fixed_hyp_path` is provided, skip the LLM and use
    # a pre-written YAML — useful for orchestrator integration tests so a
    # full iteration can run without a recursive claude invocation.
    if fixed_hyp_path:
        print(f"Phase 1: Using pre-written hypothesis: {fixed_hyp_path}")
        hyp_path = fixed_hyp_path
    else:
        print("Phase 1: Generating hypothesis...")
        hyp_path = run_hypothesis_agent(log[-20:], best, base)
        print(f"  Hypothesis written: {hyp_path}")

    # 2. Validate schema. Catch only the specific exceptions we expect —
    # an unrelated bug should propagate, not be logged as "schema_error".
    try:
        hyp = validate_hypothesis(hyp_path)
    except (jsonschema.ValidationError, FileNotFoundError, yaml.YAMLError) as e:
        entry = {'id': 'schema_error', 'title': str(hyp_path), 'category': 'unknown',
                 'outcome': 'broken', 'formal_passed': False, 'cosim_passed': False,
                 'error': str(e)}
        append_log(entry)
        print(f"  BROKEN: schema validation failed: {e}")
        return entry

    hyp_id = hyp['id']
    print(f"  [{hyp_id}] {hyp['title']}")

    # 3. Create worktree
    worktree = create_worktree(hyp_id)
    print(f"  Worktree: {worktree}")

    def log_broken(reason: str, detail: str = ''):
        entry = {**hyp, 'outcome': 'broken', 'formal_passed': False,
                 'cosim_passed': False, 'error': f"{reason}: {detail}"}
        append_log(entry)
        destroy_worktree(hyp_id)
        print(f"  BROKEN: {reason}")
        return entry

    # 4. Implement. If a pre-written hypothesis is in use AND it sets the
    # flag `skip_implementation: true`, the worktree's rtl/ is left
    # unchanged (used to test the eval gates on the baseline RTL).
    if fixed_hyp_path and hyp.get('skip_implementation'):
        print("Phase 2: Skipping implementation agent (test mode).")
    else:
        print("Phase 2: Implementing hypothesis...")
        impl_ok = run_implementation_agent(hyp_path, worktree)
        if not impl_ok:
            return log_broken("implementation_compile_failed")

    # 4b. Sandbox check — reject any change outside rtl/ + test/test_*.py.
    # The agent runs with --dangerously-skip-permissions and could silently
    # patch tools/, formal/, fpga/, test/cosim/, schemas/, bench/programs/,
    # etc. to inflate fitness. Detect that here, BEFORE any eval gate runs.
    sandbox_breaches = offlimits_changes(worktree)
    if sandbox_breaches:
        return log_broken("sandbox_violation",
                          f"agent touched off-limits paths: {sandbox_breaches}")

    # 5. Lint + synth + bench-ELFs + cosim-build
    print("Phase 3: Lint, synth, bench, cosim-build...")
    if not emit_verilog(worktree):
        return log_broken("build_failed")

    # 6. Formal gate. On failure, include both the failing check name and
    # the tail of run_all.sh stdout (which now contains the failing check's
    # logfile.txt tail, see formal/run_all.sh fail-path) so log.jsonl has
    # an actual diagnostic instead of just "formal_failed: insn_xor_ch0".
    print("Phase 4: riscv-formal...")
    formal = run_formal(worktree)
    if not formal['passed']:
        check  = formal.get('failed_check', '')
        detail = formal.get('detail', '')
        msg    = f"{check}\n{detail}".strip() if detail else check
        return log_broken("formal_failed", msg)

    # 7. Cosim gate
    print("Phase 5: Cosim...")
    cosim = run_cosim(worktree)
    if not cosim['passed']:
        return log_broken("cosim_failed", cosim.get('failed_elf',''))

    # 8. FPGA fitness
    print("Phase 6: FPGA evaluation (3 seeds parallel)...")
    fpga = run_fpga_eval(worktree)
    if fpga['placement_failed']:
        return log_broken("placement_failed")
    if fpga.get('bench_failed'):
        return log_broken("coremark_failed", fpga.get('reason', ''))

    fitness = fpga['fitness']
    delta   = ((fitness - best) / best * 100) if best > 0 else 0.0
    vs_base = ((fitness - base) / base * 100) if base > 0 else 0.0
    outcome = 'improvement' if fitness > best else 'regression'

    entry = {
        **hyp,
        'outcome':         outcome,
        'fitness':         fitness,
        'delta_pct':       round(delta, 2),
        'vs_baseline':     round(vs_base, 2),
        'fmax_mhz':        fpga['fmax_mhz'],
        'ipc_coremark':    fpga['ipc_coremark'],
        'lut4':            fpga['lut4'],
        'ff':              fpga['ff'],
        'seeds':           fpga['seeds'],
        'formal_passed':   True,
        'cosim_passed':    True,
        'error':           None,
        'implementation_notes': _read_notes(worktree),
        'timestamp':       datetime.datetime.utcnow().isoformat(),
    }
    append_log(entry)

    if outcome == 'improvement':
        msg = f"{hyp_id}: {hyp['title']} (+{delta:.1f}%)"
        accept_worktree(hyp_id, msg)
        plot_progress()
        print(f"  ACCEPTED: {fitness:.2f} ({delta:+.1f}%)")
    else:
        destroy_worktree(hyp_id)
        print(f"  REGRESSION: {fitness:.2f} ({delta:+.1f}%)")

    return entry

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
    parser.add_argument('--iterations', type=int, default=1)
    parser.add_argument('--report', action='store_true')
    parser.add_argument('--from-hypothesis', metavar='PATH', default=None,
                        help='Skip the LLM hypothesis step and use a pre-written YAML. '
                             'Useful for integration tests of the eval pipeline.')
    args = parser.parse_args()

    if args.report:
        run_report()
        return

    for i in range(1, args.iterations + 1):
        log = read_log()
        run_iteration(i, log, fixed_hyp_path=args.from_hypothesis)

if __name__ == '__main__':
    main()
