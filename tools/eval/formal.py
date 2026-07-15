"""Runs the real riscv-formal suite via formal/run_all.sh.

The real suite is generated at runtime by formal/run_all.sh (which invokes
genchecks.py against our rtl/*.sv + wrapper.sv + checks.cfg) and runs the
~45 I-base / M-ext insn checks plus reg / pc_fwd / pc_bwd / causal /
unique / cover / ill / liveness — 53 total against the V0 baseline.

If genchecks.py crashes mid-run and only emits one .sby task that
vacuously passes, the old `passed > 0 and failed == 0` rule would
return success. EXPECTED_MIN_CHECKS prevents that.
"""
import os, shutil, subprocess, json, re
from pathlib import Path

import yaml

from tools.eval._subprocess import run_pgroup


def read_nret(core_yaml_path: Path) -> int:
    """Read the `nret` field from a core.yaml. Defaults to 2 when the file
    or field is missing — preserves backward compat with cores authored
    before the nret-aware fixture (every existing core today).

    Only 1 and 2 are supported. NRET=1 selects the single-issue formal
    wrapper (wrapper_si.sv + checks_si.cfg); NRET=2 uses the dual-channel
    default (wrapper.sv + checks.cfg).
    """
    p = Path(core_yaml_path)
    if not p.exists():
        return 2
    y = yaml.safe_load(p.read_text()) or {}
    n = y.get("nret", 2)
    if n not in (1, 2):
        raise ValueError(f"core.yaml nret must be 1 or 2, got {n!r}")
    return n

# Floor on how many .sby tasks must pass for a "formal: green" result.
# V0 baseline produces 53. Allow some slack (≥50) so a future checks.cfg
# tweak that legitimately drops 1-2 checks doesn't trigger a false alarm,
# but reject a partial genchecks run that emits 1-2 tasks.
EXPECTED_MIN_CHECKS = int(os.environ.get("FORMAL_MIN_CHECKS", "50"))


# Patterns that prove SBY actually executed at least one check before the
# post-run `*.sby` glob came up empty. Any one of these in the output
# means `no_checks_generated` is the wrong label — checks DID generate,
# they just got wiped or interrupted between SBY's output and the tally.
_SBY_RAN_PATTERNS = (
    re.compile(r'^SBY \d+:\d+:\d+ \[\S+\] DONE \((PASS|FAIL|ERROR)', re.MULTILINE),
    re.compile(r'^SBY \d+:\d+:\d+ \[\S+\] engine_0: Status returned by engine', re.MULTILINE),
    re.compile(r'^make\[1\]: \*\*\* \[\S+/status\] Error', re.MULTILINE),
)


def _reclassify_no_checks_generated(output: str) -> str:
    """If run_all.sh said `no_checks_generated` but SBY output proves
    checks actually ran, return `make_failed_during_execution` instead."""
    for pat in _SBY_RAN_PATTERNS:
        if pat.search(output):
            return 'make_failed_during_execution'
    return 'no_checks_generated'


def _build_formal_env(worktree: Path, target: str | None,
                      base_env: dict | None = None) -> dict:
    """Build the subprocess env for invoking formal/run_all.sh.

    Reads cores/<target>/core.yaml's `nret` field (defaulting to 2) and,
    when nret=1, points run_all.sh at the single-issue wrapper + checks
    config so the agent's RTL exposes only the channel-0 RVFI ports.
    nret=2 leaves WRAPPER/CHECKS_CFG unset; run_all.sh defaults to
    formal/wrapper.sv + formal/checks.cfg.
    """
    worktree_path = Path(worktree).resolve()
    env = dict(base_env) if base_env is not None else os.environ.copy()
    if target is None:
        return env
    env["RTL_DIR"] = f"cores/{target}/rtl"
    env["CORE_NAME"] = target
    nret = read_nret(worktree_path / "cores" / target / "core.yaml")
    if nret == 1:
        env["WRAPPER"] = str(worktree_path / "formal" / "wrapper_si.sv")
        env["CHECKS_CFG"] = str(worktree_path / "formal" / "checks_si.cfg")
    return env


def _cleanup_formal_workdir(worktree_path: Path, target: str | None) -> None:
    """Remove this run's per-PID riscv-formal work dir after the tally has
    been parsed.

    formal/run_all.sh (contract, read-only) names each run's work dir
    `formal/riscv-formal/cores/<CORE_NAME>-<$$>` and only reaps stale ones
    itself on the *next* invocation for the same CORE_NAME. A target
    that's only formal-checked once per orchestrator iteration would
    otherwise leave one SBY work dir (SMT traces, yosys IR, per-check
    engine logs -- often 100+ MB) behind per iteration for the life of a
    rep. formal.py has no way to learn its own bash child's PID through
    run_pgroup's CompletedProcess return value, so this globs
    `cores/<target>-*` rather than a single exact path (documented
    fallback, task-7 brief Step 3).

    Only removes a match whose PID suffix names a process that is no
    longer alive -- mirroring run_all.sh's own stale-work-dir reaper --
    so a concurrent invocation (e.g. the agent self-checking via
    `bash formal/run_all.sh` mid-implementation while the orchestrator's
    own end-of-iteration eval is also in flight) is never touched.

    Guard: BENCH_KEEP_FORMAL_WORKDIR=1 skips cleanup entirely (debugging).
    The captured output tail (in the returned dict) and
    formal/last_run-<PID>.log are untouched either way.
    """
    if target is None or os.environ.get("BENCH_KEEP_FORMAL_WORKDIR") == "1":
        return
    cores_dir = worktree_path / "formal" / "riscv-formal" / "cores"
    if not cores_dir.is_dir():
        return
    prefix = f"{target}-"
    for stale in cores_dir.glob(f"{prefix}*"):
        pid_str = stale.name[len(prefix):]
        if not pid_str.isdigit():
            continue
        pid = int(pid_str)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            shutil.rmtree(stale, ignore_errors=True)
        except PermissionError:
            # Process exists (owned by someone else) -- not our dir to
            # remove while it may still be in use.
            continue


def run_formal(worktree: str, target: str | None = None) -> dict:
    """
    Args:
      worktree: path to the repo root.
      target:   optional core name (e.g. 'v1').  When set, injects
                RTL_DIR=cores/<target>/rtl and CORE_NAME=<target> into
                the subprocess environment so run_all.sh picks up that
                core's RTL instead of the default rtl/ directory. When
                that core's core.yaml declares nret=1, also injects
                WRAPPER=formal/wrapper_si.sv and CHECKS_CFG=formal/checks_si.cfg
                so the single-issue formal flow runs instead of the
                default dual-channel one.

    Returns:
      {'passed': True, 'checks_passed': N}
      {'passed': False, 'failed_check': name, 'detail': str}
    """
    worktree_path = Path(worktree).resolve()
    run_script = worktree_path / "formal" / "run_all.sh"
    if not run_script.exists():
        return {'passed': False, 'failed_check': 'setup',
                'detail': f'formal/run_all.sh missing in {worktree}'}

    env = _build_formal_env(worktree_path, target)

    # The per-PID SBY work dir this invocation creates under
    # formal/riscv-formal/cores/ is cleaned up in `finally` below, once
    # the tally (or failing-check log tail) has been captured — success
    # and failure runs both. See _cleanup_formal_workdir's docstring.
    try:
        try:
            result = run_pgroup(
                ["bash", str(run_script)],
                cwd=worktree_path, capture_output=True, text=True,
                timeout=2700,  # 45 min ceiling for all ~45 checks running in parallel via make -j
                env=env,
            )
        except subprocess.TimeoutExpired as e:
            # The formal harness exceeded its wall-clock ceiling. This MUST
            # not propagate — an unhandled TimeoutExpired in run_slot kills
            # the entire ThreadPoolExecutor batch, which kills the rep
            # (round_id stays at whatever round was in flight, the
            # orchestrator's main loop dies, and the rep finalizes at iter=N
            # instead of running its full N=15). Observed live on
            # deepseek-v4-pro reps where some hypotheses produced SMT
            # problems that bitwuzla couldn't close in 30 minutes.
            # Return a slot-broken outcome with a recognizable error class
            # so the report's broken_by_class table surfaces it cleanly.
            # run_pgroup preserves text=True, so e.stdout/e.stderr arrive as
            # str. (subprocess.run with text=True would behave the same way —
            # the prior .decode() call was always latent, but TimeoutExpired
            # never fired in practice under the 30-min ceiling so it stayed
            # hidden until kimi-rep3 hit the bumped 45-min ceiling and an
            # AttributeError crashed the orchestrator. See commit bfe9f84.)
            partial = (e.stdout or "") + (e.stderr or "")
            return {
                'passed': False,
                'failed_check': 'timeout',
                'detail': (f'run_all.sh exceeded {e.timeout}s wall-clock'
                           + ('\n--- partial output (tail) ---\n' + partial[-2000:]
                              if partial else '')),
            }
        output = result.stdout + result.stderr

        # run_all.sh prints a final "Formal: <N> passed, <M> failed" tally line.
        tally = re.search(r'Formal:\s+(\d+)\s+passed,\s+(\d+)\s+failed', output)
        if tally:
            passed, failed = int(tally.group(1)), int(tally.group(2))
            if failed > 0 or result.returncode != 0:
                fail_line = re.search(r'Failed:\s+(\S+)', output)
                failed_check = fail_line.group(1) if fail_line else 'unknown'
                # `no_checks_generated` is run_all.sh's fallback when the
                # post-run `for sby_file in *.sby` glob finds zero matches.
                # That can mean genchecks.py crashed (the intended case) OR
                # that something between genchecks and the tally — most
                # commonly the implementer agent's bash tool — wiped or
                # corrupted the checks directory mid-run. Distinguish so
                # postmortems can tell "tooling never produced checks" from
                # "real SBY work happened then the directory was molested".
                if failed_check == 'no_checks_generated':
                    failed_check = _reclassify_no_checks_generated(output)
                return {
                    'passed': False,
                    'failed_check': failed_check,
                    'checks_passed': passed,
                    'checks_failed': failed,
                    'detail': output[-4000:],
                }
            if passed < EXPECTED_MIN_CHECKS:
                return {
                    'passed': False,
                    'failed_check': 'too_few_checks_generated',
                    'checks_passed': passed,
                    'checks_expected_min': EXPECTED_MIN_CHECKS,
                    'detail': f'genchecks emitted only {passed} tasks (expected ≥ {EXPECTED_MIN_CHECKS})',
                }
            return {'passed': True, 'checks_passed': passed}

        # Script didn't produce a tally — setup error (missing riscv-formal repo,
        # genchecks.py crash, etc.).
        return {
            'passed': False,
            'failed_check': 'setup',
            'detail': output[-4000:],
        }
    finally:
        _cleanup_formal_workdir(worktree_path, target)


if __name__ == '__main__':
    import sys
    result = run_formal(sys.argv[1] if len(sys.argv) > 1 else '.', sys.argv[2] if len(sys.argv) > 2 else None)
    print(json.dumps(result, indent=2))
