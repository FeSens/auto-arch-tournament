#!/usr/bin/env python3
"""Hardcoded AutoResearch loop. The LLM never touches this file."""
import argparse, json, datetime, os, shutil, subprocess, re, threading, sys
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

LOG_PATH       = Path("experiments/log.jsonl")   # rebound in main() per target
PLOT_PATH      = Path("experiments/progress.png") # rebound in main() per target
HYP_SCHEMA     = json.loads(Path("schemas/hypothesis.schema.json").read_text())
RESULT_SCHEMA  = json.loads(Path("schemas/eval_result.schema.json").read_text())


def log_path_for(target: str) -> Path:
    return Path("cores") / target / "experiments" / "log.jsonl"


def plot_path_for(target: str) -> Path:
    return Path("cores") / target / "experiments" / "progress.png"

# Serializes append_log across concurrent tournament slots. The body of
# append_log writes log.jsonl, regenerates progress.png, then git-adds
# and commits both — three operations that all touch the index. Without
# this lock, two slots finishing within the same ~second would race on
# .git/index.lock and crash the round.
_LOG_LOCK = threading.Lock()

# Don't-touch sandbox: anything outside the per-target allowed patterns that
# the agent touches is rejected before the eval gates run. Without this an
# agent could silently soften checks.cfg, the cosim main.cpp, or the
# fpga.py CRC table and inflate its own fitness score.
#
# Permitted modifications per CLAUDE.md "What hypotheses MAY change":
#   - cores/<target>/rtl/ (any file)
#   - cores/<target>/test/test_*.py (cocotb suites for new modules)
#   - cores/<target>/implementation_notes.md (the agent's own writeup)
#   - cores/<target>/core.yaml
#
# Everything else is off-limits.
def allowed_patterns_for(target: str) -> tuple:
    base = re.escape(f"cores/{target}")
    return (
        re.compile(rf"^{base}/rtl/.+"),
        re.compile(rf"^{base}/test/test_[^/]+\.py$"),
        re.compile(rf"^{base}/implementation_notes\.md$"),
        re.compile(rf"^{base}/core\.yaml$"),
    )


def path_is_allowed(path: str, patterns: tuple) -> bool:
    return any(p.match(path) for p in patterns)


def offlimits_changes(worktree: str, patterns: tuple) -> list:
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
            if p and not path_is_allowed(p, patterns):
                bad.append(p)
    return bad

def update_core_yaml_current(target: str, repo_root: Path | None = None, *,
                              fmax_mhz: float, lut4: int, ff: int | None,
                              coremark_iter_s: float, source_id: str) -> None:
    """Write the `current:` section of cores/<target>/core.yaml.

    Called from the accept path (after run_fpga_eval succeeds and the
    hypothesis is accepted as an improvement).

    Args:
      target          -- core name under cores/.
      repo_root       -- repo root path; defaults to cwd if None.
      fmax_mhz        -- achieved Fmax in MHz.
      lut4            -- achieved LUT4 count.
      ff              -- achieved flip-flop count (may be None).
      coremark_iter_s -- CoreMark iterations/second.
      source_id       -- hypothesis ID that produced this result.
    """
    repo_root = Path(repo_root or ".").resolve()
    yaml_path = repo_root / "cores" / target / "core.yaml"
    if not yaml_path.exists():
        return  # no yaml to update; older cores may not have one.
    y = yaml.safe_load(yaml_path.read_text()) or {}
    y["current"] = {
        "fmax_mhz": fmax_mhz,
        "lut4": lut4,
        "ff": ff,
        "coremark_iter_s": coremark_iter_s,
        "coremark_per_mhz": round(coremark_iter_s / fmax_mhz, 4) if fmax_mhz else None,
        "source_id": source_id,
        "updated": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    yaml_path.write_text(yaml.safe_dump(y, sort_keys=False))


def _current_target() -> str | None:
    """Extract target from LOG_PATH (set in main() to cores/<target>/experiments/log.jsonl)."""
    parts = LOG_PATH.parts
    if len(parts) >= 2 and parts[0] == "cores":
        return parts[1]
    return None


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
        # If a per-iteration hypothesis YAML exists for this entry's id, read
        # its proposal content and embed it under a 'hypothesis' sub-object
        # before writing the log line. This keeps log.jsonl as the single
        # journal of both proposals and outcomes.
        target = _current_target()
        hyp_yaml_path: Path | None = None
        if target:
            candidate = Path("cores") / target / "experiments" / "hypotheses" / f"{entry.get('id', '')}.yaml"
            if candidate.exists():
                hyp_yaml_path = candidate
                try:
                    y = yaml.safe_load(candidate.read_text()) or {}
                    entry["hypothesis"] = {
                        "motivation": y.get("motivation"),
                        "hypothesis": y.get("hypothesis"),
                        "expected_impact": y.get("expected_impact"),
                        "changes": y.get("changes"),
                    }
                except Exception:
                    pass  # malformed YAML — log the entry without hypothesis content

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
        if target and entry.get("outcome") == "improvement":
            yaml_path = Path("cores") / target / "core.yaml"
            update_core_yaml_current(
                target=target,
                fmax_mhz=entry["fmax_mhz"],
                lut4=entry["lut4"],
                ff=entry.get("ff"),
                coremark_iter_s=entry.get("coremark_iter_s") or entry.get("ipc_coremark"),
                source_id=entry["id"],
            )
            if yaml_path.exists():
                subprocess.run(["git", "add", str(yaml_path)], check=True)
        subprocess.run(
            ["git", "commit", "-m",
             f"log: {entry.get('id','unknown')} {entry.get('outcome','unknown')}"],
            check=True,
        )
        # After the commit succeeds, delete the transient hypothesis YAML.
        # Deletion is intentionally post-commit: if the commit fails, the YAML
        # stays on disk for debugging. The YAML is untracked (gitignored), so
        # no git rm needed.
        if hyp_yaml_path is not None:
            try:
                hyp_yaml_path.unlink()
            except FileNotFoundError:
                pass

def validate_hypothesis(hyp_path: str) -> dict:
    with open(hyp_path) as f:
        hyp = yaml.safe_load(f)
    jsonschema.validate(hyp, HYP_SCHEMA)
    return hyp

def emit_verilog(worktree: str, target: str | None = None) -> bool:
    """Prepare a worktree for evaluation.

    SV-source-of-truth project: there is no Chisel emit step. Instead this
    function (1) lints the target's RTL directory (rtl/ or cores/<target>/rtl/)
    with verilator, (2) synthesizes core_bench via yosys for nextpnr, (3) builds
    the bench ELFs (selftest + coremark), and (4) rebuilds the Verilator cosim
    binary against the worktree's RTL. Any failure here is a "broken" outcome
    — the hypothesis didn't even compile.

    Args:
      worktree -- absolute path to the worktree directory.
      target   -- core name under cores/. When set, RTL lives in
                  cores/<target>/rtl/ instead of rtl/.
    """
    worktree = str(Path(worktree).resolve())

    # 1. Verilator lint. Catches syntax errors before slower steps.
    if target:
        rtl_glob = f"cores/{target}/rtl/*.sv"
        rtl_dir = f"cores/{target}/rtl"
        lint_cmd = (
            f"if ls {rtl_glob} >/dev/null 2>&1; then "
            f"verilator --lint-only -Wall -Wno-MULTITOP -sv +incdir+{rtl_dir} {rtl_glob}; "
            f"else echo 'lint: no source files in {rtl_glob}'; exit 1; fi"
        )
    else:
        lint_cmd = (
            "if ls rtl/*.sv >/dev/null 2>&1; then "
            "verilator --lint-only -Wall -Wno-MULTITOP -sv +incdir+rtl rtl/*.sv; "
            "else echo 'lint: no source files in rtl/'; exit 1; fi"
        )
    lint = subprocess.run(
        ["bash", "-lc", lint_cmd],
        cwd=worktree, capture_output=True,
    )
    if lint.returncode != 0:
        return False

    # 2. Yosys synth (writes generated/synth.json for nextpnr).
    gen_dir = Path(worktree) / "cores" / target / "generated" if target else Path(worktree) / "generated"
    gen_dir.mkdir(parents=True, exist_ok=True)
    synth_env = {**os.environ, "RTL_DIR": f"cores/{target}/rtl", "GEN_DIR": f"cores/{target}/generated"} if target else None
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

def fork_core(target: str, base: str, repo_root: Path | None = None,
              interactive: bool | None = None) -> None:
    """Create cores/<target>/ by forking from cores/<base>/.

    Copies rtl/, test/, core.yaml from base. Does NOT copy CORE_PHILOSOPHY.md
    (always per-core). Does NOT copy experiments/ (new core gets its own log).
    Resets core.yaml's current: section. Prompts user for philosophy via TTY
    if interactive (None → auto-detect from sys.stdin.isatty()).
    """
    repo_root = Path(repo_root or ".").resolve()
    tgt = repo_root / "cores" / target
    src = repo_root / "cores" / base

    if tgt.exists():
        raise SystemExit(
            f"cores/{target}/ already exists. Drop BASE= to continue iterating, "
            f"or `git rm -r cores/{target}` to start over."
        )
    if not src.exists():
        raise SystemExit(f"BASE core 'cores/{base}/' does not exist.")

    tgt.mkdir(parents=True)
    # Copy rtl/ and test/ trees.
    if (src / "rtl").exists():
        shutil.copytree(src / "rtl", tgt / "rtl")
    (tgt / "test").mkdir(exist_ok=True)
    if (src / "test").exists():
        for p in (src / "test").glob("test_*.py"):
            shutil.copy2(p, tgt / "test" / p.name)
        # Also copy _helpers.py and conftest.py if present (per-core test infra).
        for p in (src / "test").glob("_helpers.py"):
            shutil.copy2(p, tgt / "test" / p.name)
        for p in (src / "test").glob("conftest.py"):
            shutil.copy2(p, tgt / "test" / p.name)
    # Copy and rewrite core.yaml.
    if (src / "core.yaml").exists():
        y = yaml.safe_load((src / "core.yaml").read_text()) or {}
        y["name"] = target
        y["current"] = {}
        (tgt / "core.yaml").write_text(yaml.safe_dump(y, sort_keys=False))
    # Always create an empty experiments/ for the new core.
    (tgt / "experiments").mkdir(exist_ok=True)
    # Philosophy prompt (TTY-gated).
    philo = tgt / "CORE_PHILOSOPHY.md"
    if interactive is None:
        interactive = sys.stdin.isatty()
    if interactive:
        sys.stderr.write(
            f"Optional: write the philosophy for cores/{target} (constraints, "
            f"style, intent).\n"
            f"Press Enter on an empty line to finish (just press Enter now to skip).\n"
        )
        sys.stderr.flush()
        lines: list[str] = []
        while True:
            try:
                line = input()
            except EOFError:
                break  # Ctrl-D also accepted
            if line == "":
                break
            lines.append(line)
        text = ("\n".join(lines) + "\n") if lines else ""
        philo.write_text(text)
    else:
        philo.write_text("")  # silent, headless-safe.
    # Commit the fork.
    subprocess.run(["git", "-C", str(repo_root), "add", f"cores/{target}/"],
                   check=True)
    subprocess.run(
        ["git", "-C", str(repo_root), "commit", "-m",
         f"feat: fork cores/{target} from cores/{base}"],
        check=True,
    )


def _run_baseline_retest(target: str):
    """Run a one-shot eval on the freshly created core's RTL.

    Writes a single 'baseline' entry to the per-target log so subsequent
    hypothesis rounds have a fitness anchor. Aborts the run if any gate
    fails — the user investigates while the core is left intact.

    Args:
      target -- core name under cores/.
    """
    # Re-emit verilog + run gates against the main repo's working copy
    # (the active branch is checked out). We don't create a worktree —
    # the baseline retest IS the branch tip, not a hypothesis.
    repo_root = str(Path(".").resolve())
    if not emit_verilog(repo_root, target=target):
        raise SystemExit(f"baseline retest: emit_verilog failed for cores/{target}.")
    formal = run_formal(repo_root, target=target)
    if not formal['passed']:
        raise SystemExit(
            f"baseline retest: formal failed for cores/{target}: "
            f"{formal.get('failed_check','')}"
        )
    cosim = run_cosim(repo_root, target=target)
    if not cosim['passed']:
        raise SystemExit(
            f"baseline retest: cosim failed for cores/{target}: "
            f"{cosim.get('failed_elf','')}"
        )
    fpga = run_fpga_eval(repo_root, target=target)
    if fpga.get('placement_failed') or fpga.get('bench_failed'):
        raise SystemExit(f"baseline retest: fpga eval failed for cores/{target}.")

    sha = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    entry = {
        'id':            f'baseline-{target}-{sha}',
        'title':         f'Baseline retest for cores/{target}',
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
        'timestamp':     datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
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
    parser.add_argument('--coremark-target', type=int, default=None,
                        help='CoreMark iter/s target for two-phase Pareto accept.')
    parser.add_argument('--lut-target', type=int, default=None,
                        help='LUT4 target for two-phase Pareto accept.')
    parser.add_argument('--target', default=None,
                        help='Core name under cores/. Required for non-report invocations.')
    parser.add_argument('--base', default='baseline',
                        help='When forking a new --target, copy from cores/<base>/. '
                             'Default: baseline. Ignored if --target already exists.')
    args = parser.parse_args()

    # --target is required for all non-report invocations.
    if not args.report and not args.target:
        parser.error("--target is required. Available cores: " +
                     ", ".join(sorted(
                         p.name for p in Path("cores").iterdir()
                         if p.is_dir()
                     ) if Path("cores").exists() else []))

    # Flag validation.
    if args.coremark_target is not None and args.coremark_target <= 0:
        raise SystemExit("--coremark-target must be positive.")
    if args.lut_target is not None and args.lut_target <= 0:
        raise SystemExit("--lut-target must be positive.")

    # Per-target log/plot. Rebound as globals so read_log/append_log pick them
    # up without needing to thread the paths through every call.
    global LOG_PATH, PLOT_PATH
    if args.target:
        LOG_PATH  = log_path_for(args.target)
        PLOT_PATH = plot_path_for(args.target)

    if args.report:
        run_report()
        return

    targets = {}
    if args.coremark_target is not None:
        targets["coremark"] = args.coremark_target
    if args.lut_target is not None:
        targets["lut"] = args.lut_target

    # Fork-on-create: if cores/<target>/ is absent, fork from cores/<base>/.
    target_dir = Path("cores") / args.target
    if not target_dir.exists():
        fork_core(args.target, args.base)
        # Run baseline retest on the freshly forked core.
        print(f"[orchestrator] freshly forked cores/{args.target} — running baseline retest",
              flush=True)
        _run_baseline_retest(args.target)

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
            target_branch="main",
            target=args.target,
        )

if __name__ == '__main__':
    main()
