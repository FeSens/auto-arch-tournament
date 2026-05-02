"""Runs the real riscv-formal suite via formal/run_all.sh.

The real suite is generated at runtime by formal/run_all.sh (which invokes
genchecks.py against our rtl/*.sv + wrapper.sv + checks.cfg) and runs the
~45 I-base / M-ext insn checks plus reg / pc_fwd / pc_bwd / causal /
unique / cover / ill / liveness — 53 total against the V0 baseline.

If genchecks.py crashes mid-run and only emits one .sby task that
vacuously passes, the old `passed > 0 and failed == 0` rule would
return success. EXPECTED_MIN_CHECKS prevents that.
"""
import os, subprocess, json, re
from pathlib import Path

# Floor on how many .sby tasks must pass for a "formal: green" result.
# V0 baseline produces 53. Allow some slack (≥50) so a future checks.cfg
# tweak that legitimately drops 1-2 checks doesn't trigger a false alarm,
# but reject a partial genchecks run that emits 1-2 tasks.
EXPECTED_MIN_CHECKS = int(os.environ.get("FORMAL_MIN_CHECKS", "50"))


def run_formal(worktree: str, target: str | None = None) -> dict:
    """
    Args:
      worktree: path to the repo root.
      target:   optional core name (e.g. 'v1').  When set, injects
                RTL_DIR=cores/<target>/rtl and CORE_NAME=<target> into
                the subprocess environment so run_all.sh picks up that
                core's RTL instead of the default rtl/ directory.

    Returns:
      {'passed': True, 'checks_passed': N}
      {'passed': False, 'failed_check': name, 'detail': str}
    """
    worktree_path = Path(worktree).resolve()
    run_script = worktree_path / "formal" / "run_all.sh"
    if not run_script.exists():
        return {'passed': False, 'failed_check': 'setup',
                'detail': f'formal/run_all.sh missing in {worktree}'}

    env = os.environ.copy()
    if target is not None:
        env["RTL_DIR"] = f"cores/{target}/rtl"
        env["CORE_NAME"] = target

    try:
        result = subprocess.run(
            ["bash", str(run_script)],
            cwd=worktree_path, capture_output=True, text=True,
            timeout=1800,  # 30 min ceiling for all ~45 checks running in parallel via make -j
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
        partial = ((e.stdout or b"").decode("utf-8", errors="replace")
                   + (e.stderr or b"").decode("utf-8", errors="replace"))
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
            return {
                'passed': False,
                'failed_check': fail_line.group(1) if fail_line else 'unknown',
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


if __name__ == '__main__':
    import sys
    result = run_formal(sys.argv[1] if len(sys.argv) > 1 else '.', sys.argv[2] if len(sys.argv) > 2 else None)
    print(json.dumps(result, indent=2))
