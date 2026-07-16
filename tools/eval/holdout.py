"""Held-out benchmark eval (E3 Task 3): build the bench/holdout kernel
ELFs and the target's cosim binary if missing, run each kernel, validate
its UART line + the sim's JSON marker, and score iter/sec using a
measured Fmax.

bench/holdout/ (five kernels: dhrystone, aha-mont64, crc32, matmult-int,
edn) and its Makefile are Task 1's; each kernel prints exactly one UART
line `HOLDOUT <kernel> reps=<R> status=PASS|FAIL` (see
bench/holdout/support/main_wrapper.c) bracketed by the same
BENCH_START/BENCH_STOP MMIO markers CoreMark uses.

The sim invocation (elf, cycle ceiling, --bench --istall --dstall) and
the build-if-missing path for cores/<target>/obj_dir/cosim_sim mirror
tools/eval/fpga.py's run_coremark_ipc and tools/orchestrator.py's
cosim-build step, so held-out cycle counts are directly comparable to
the CoreMark fitness path. The final-JSON-line parsing is copied (not
imported) from tools/eval/fpga.py:run_coremark_ipc, which inlines the
same logic rather than exposing it as a standalone function.
"""
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

from tools.eval.formal import read_nret
from tools.eval._subprocess import run_pgroup

HOLDOUT_KERNELS = ("dhrystone", "aha-mont64", "crc32", "matmult-int", "edn")

HOLDOUT_BUILD_DIR = Path("bench/holdout/build")
HOLDOUT_MAKEFILE = Path("bench/holdout/Makefile")

# Sim invocation contract: must match the fitness path (tools/eval/fpga.py
# run_coremark_ipc / COREMARK_SIM_FLAGS) so held-out cycle counts are
# comparable to CoreMark's -- same 50M-cycle ceiling, same bus-stall model.
SIM_CYCLE_CEILING = "50000000"
SIM_FLAGS = ["--bench", "--istall", "--dstall"]

_UART_STATUS_RE = re.compile(r'HOLDOUT\s+(\S+)\s+reps=(\d+)\s+status=(PASS|FAIL)')


def _build_holdout_elfs(worktree: Path) -> None:
    """Build bench/holdout/build/*.elf via the Task 1 Makefile if any
    kernel's ELF is missing. Rebuilds all of them (Makefile's `all`
    target) rather than a partial set -- cheap and keeps this simple.
    """
    missing = [
        k for k in HOLDOUT_KERNELS
        if not (worktree / HOLDOUT_BUILD_DIR / f"{k}.elf").exists()
    ]
    if not missing:
        return
    result = subprocess.run(
        ["make", "-f", str(HOLDOUT_MAKEFILE), "all"],
        cwd=worktree, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"FATAL: bench/holdout/Makefile build failed (rc={result.returncode}):\n"
            f"{result.stdout[-2000:]}\n{result.stderr[-2000:]}"
        )


def _build_sim_env(worktree: Path, target: str) -> dict:
    """Env for `bash test/cosim/build.sh`, mirroring tools/eval/cosim.py's
    _build_cosim_env / tools/orchestrator.py's cosim-build step: RTL_DIR
    and OBJ_DIR point at the target's core, NRET comes from core.yaml
    (defaults to 2)."""
    env = os.environ.copy()
    env["RTL_DIR"] = f"cores/{target}/rtl"
    env["OBJ_DIR"] = f"cores/{target}/obj_dir"
    env["NRET"] = str(read_nret(worktree / "cores" / target / "core.yaml"))
    return env


def _build_sim_binary(worktree: Path, target: str) -> Path:
    """Build cores/<target>/obj_dir/cosim_sim via test/cosim/build.sh if
    it doesn't already exist."""
    sim_bin = worktree / "cores" / target / "obj_dir" / "cosim_sim"
    if sim_bin.exists():
        return sim_bin
    env = _build_sim_env(worktree, target)
    result = subprocess.run(
        ["bash", "test/cosim/build.sh"],
        cwd=worktree, capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"FATAL: test/cosim/build.sh failed for target {target} "
            f"(rc={result.returncode}):\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}"
        )
    if not sim_bin.exists():
        raise RuntimeError(
            f"FATAL: test/cosim/build.sh reported success but {sim_bin} is missing"
        )
    return sim_bin


def _parse_sim_marker(stdout: str) -> dict:
    """Parse the final JSON marker line from cosim_sim stdout.

    Copied from tools/eval/fpga.py:run_coremark_ipc's marker-parsing logic
    (last non-blank stdout line is the
    {"ebreak":...,"oob":...,"bench_bracketed":...,"uart":...} JSON that
    test/cosim/main.cpp emits in --bench mode); inlined there rather than
    factored out, so this is a copy, not an import, per the don't-import-
    private-helpers rule for this module.
    """
    lines = [l for l in stdout.splitlines() if l.strip()]
    if not lines:
        raise ValueError("no output from sim")
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError as e:
        raise ValueError(f"malformed sim output: {e}: {lines[-1][:500]}") from e


def _parse_uart_status(uart: str, kernel: str) -> tuple:
    """Extract (reps, passed) from the kernel's `HOLDOUT <kernel>
    reps=<R> status=PASS|FAIL` UART line (see
    bench/holdout/support/main_wrapper.c). Returns (0, False) if the line
    is absent, unparsable, or names a different kernel (guards against a
    mixed-up ELF/kernel pairing silently validating)."""
    m = _UART_STATUS_RE.search(uart)
    if not m or m.group(1) != kernel:
        return 0, False
    return int(m.group(2)), m.group(3) == "PASS"


def run_kernel(elf_root: Path, sim_bin: Path, kernel: str, *, cwd: Path | None = None) -> dict:
    """Run one held-out kernel ELF on the sim and validate it.

    `elf_root` is where the kernel ELF is looked up (HOLDOUT_BUILD_DIR
    relative to it); `cwd` is where the sim process runs, defaulting to
    `elf_root` when not given (the historical worktree-is-everything
    behavior). run_holdout passes these separately so a bundle-clone
    scorer can source ELFs from a holdout_dir distinct from the
    champion worktree the simulator runs from.

    Returns {'cycles': int, 'reps': int, 'validated': bool} on success,
    plus {'reason': str} with cycles=reps=0 on any failure -- mirroring
    tools/eval/fpga.py's run_coremark_ipc, which credits nothing on a
    failed run rather than reporting a partial/tainted cycle count.
    """
    elf = elf_root / HOLDOUT_BUILD_DIR / f"{kernel}.elf"
    if not elf.exists():
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': f'missing_elf: {elf}'}

    try:
        result = run_pgroup(
            [str(sim_bin), str(elf), SIM_CYCLE_CEILING] + SIM_FLAGS,
            capture_output=True, text=True, timeout=600,
            cwd=cwd if cwd is not None else elf_root,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': f'sim_harness_error: {e}'}

    try:
        marker = _parse_sim_marker(result.stdout)
    except ValueError as e:
        return {'cycles': 0, 'reps': 0, 'validated': False, 'reason': str(e)}

    if not marker.get('ebreak', False):
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': 'maxcycles_hit_before_ebreak'}
    if marker.get('oob', False):
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': 'oob_memory_access'}
    if not marker.get('bench_bracketed', False):
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': f'bench_markers_missing: '
                          f'start={marker.get("bench_start_cycle")} '
                          f'stop={marker.get("bench_stop_cycle")}'}

    uart = marker.get('uart', '')
    reps, passed = _parse_uart_status(uart, kernel)
    if not passed:
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': f'uart_status_fail_or_missing: {uart[-500:]}'}

    cycles = int(marker['bench_stop_cycle']) - int(marker['bench_start_cycle'])
    if cycles <= 0:
        return {'cycles': 0, 'reps': 0, 'validated': False,
                'reason': f'invalid_bench_bracket: '
                          f'start={marker.get("bench_start_cycle")} '
                          f'stop={marker.get("bench_stop_cycle")}'}

    return {'cycles': cycles, 'reps': reps, 'validated': True}


def run_holdout(worktree: str, target: str, fmax_mhz: float,
                 holdout_dir: str | None = None) -> dict:
    """Build (if needed), run, and score all HOLDOUT_KERNELS against
    cores/<target>.

    `holdout_dir`, if given, is where the kernel ELFs are built/looked
    up (bench/holdout/build/*.elf) instead of `worktree`. The simulator
    itself (cores/<target>/obj_dir/cosim_sim) always builds/looks up
    from `worktree`, since it depends on that target's RTL. This split
    lets a caller score a champion checked out from a bundle clone that
    lacks bench/holdout (by E3 design) against a shared, core-independent
    kernel directory. Default (None) is the pre-existing behavior:
    worktree drives both.

    Returns:
      {'kernels': {name: {'cycles': int, 'reps': int, 'iter_s': float,
                           'validated': bool, ['reason': str]}},
       'geomean_iter_s': float,   # geomean over validated kernels only;
                                  # 0.0 if none validated
       'all_validated': bool}
    """
    worktree_path = Path(worktree).resolve()
    elf_root = Path(holdout_dir).resolve() if holdout_dir is not None else worktree_path
    _build_holdout_elfs(elf_root)
    sim_bin = _build_sim_binary(worktree_path, target)

    kernels = {}
    for kernel in HOLDOUT_KERNELS:
        r = run_kernel(elf_root, sim_bin, kernel, cwd=worktree_path)
        entry = {
            'cycles': r['cycles'],
            'reps': r['reps'],
            'iter_s': (fmax_mhz * 1e6 * r['reps'] / r['cycles']) if r['validated'] else 0.0,
            'validated': r['validated'],
        }
        if not r['validated']:
            entry['reason'] = r['reason']
        kernels[kernel] = entry

    validated_iters = [k['iter_s'] for k in kernels.values() if k['validated']]
    all_validated = len(validated_iters) == len(HOLDOUT_KERNELS)
    if validated_iters:
        # Geomean via mean-of-logs (no numpy dependency, no overflow risk
        # from math.prod on several large iter_s values).
        geomean_iter_s = math.exp(
            sum(math.log(v) for v in validated_iters) / len(validated_iters)
        )
    else:
        geomean_iter_s = 0.0

    return {
        'kernels': kernels,
        'geomean_iter_s': geomean_iter_s,
        'all_validated': all_validated,
    }


if __name__ == '__main__':
    result = run_holdout(sys.argv[1], sys.argv[2], float(sys.argv[3]))
    print(json.dumps(result, indent=2))
