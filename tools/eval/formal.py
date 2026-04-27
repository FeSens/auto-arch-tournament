"""Runs the real riscv-formal suite via formal/run_all.sh.

The old implementation scanned formal/checks/*.sby, but those were stub files
that don't instantiate any riscv-formal properties. The real suite is generated
at runtime by formal/run_all.sh (which invokes genchecks.py against our Core.sv
+ wrapper.sv + checks.cfg) and runs ~45 I-base + reg/pc/causal checks.
"""
import subprocess, json, re
from pathlib import Path

def run_formal(worktree: str) -> dict:
    """
    Returns:
      {'passed': True, 'checks_passed': N}
      {'passed': False, 'failed_check': name, 'detail': str}
    """
    worktree_path = Path(worktree).resolve()
    run_script = worktree_path / "formal" / "run_all.sh"
    if not run_script.exists():
        return {'passed': False, 'failed_check': 'setup',
                'detail': f'formal/run_all.sh missing in {worktree}'}

    result = subprocess.run(
        ["bash", str(run_script)],
        cwd=worktree_path, capture_output=True, text=True,
        timeout=1800,  # 30 min ceiling for all ~45 checks running in parallel via make -j
    )
    output = result.stdout + result.stderr

    # run_all.sh prints a final "Formal: <N> passed, <M> failed" tally line.
    tally = re.search(r'Formal:\s+(\d+)\s+passed,\s+(\d+)\s+failed', output)
    if tally:
        passed, failed = int(tally.group(1)), int(tally.group(2))
        if passed > 0 and failed == 0 and result.returncode == 0:
            return {'passed': True, 'checks_passed': passed}
        fail_line = re.search(r'Failed:\s+(\S+)', output)
        return {
            'passed': False,
            'failed_check': fail_line.group(1) if fail_line else 'unknown',
            'detail': output[-4000:],
        }

    # Script didn't produce a tally — setup error (missing riscv-formal repo,
    # genchecks.py crash, etc.).
    return {
        'passed': False,
        'failed_check': 'setup',
        'detail': output[-4000:],
    }


if __name__ == '__main__':
    import sys
    result = run_formal(sys.argv[1] if len(sys.argv) > 1 else '.')
    print(json.dumps(result, indent=2))
