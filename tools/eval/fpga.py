"""Runs 3 nextpnr seeds in parallel, returns median Fmax and CoreMark iter/sec."""
import asyncio, os, re, json, subprocess, statistics
from pathlib import Path

SEEDS = [1, 2, 3]
NEXTPNR_SCRIPT = "fpga/scripts/nextpnr_run.sh"
PORTME_H = "bench/programs/coremark/baremetal/core_portme.h"
# Canonical 2K-config CoreMark CRCs (the EEMBC-published reporting size,
# what VexRiscv et al. use). Bench Makefile defaults match: 2K data,
# -O3, ITERATIONS=10. Verified against VexRiscv's pre-compiled
# coremark_rv32im.bin — same seedcrc/crclist/crcmatrix/crcstate, same
# crcfinal. Mismatch at any of these is a benchmark failure.
COREMARK_EXPECTED = {
    'seedcrc':   0xe9f5,
    'crclist':   0xe714,
    'crcmatrix': 0x1fd7,
    'crcstate':  0x8e3a,
    'crcfinal':  0xfcaf,
}
# CoreMark sim flags: random ~22% imem+dmem backpressure (matching
# VexRiscv's iStall/dStall regression model — see
# VexRiscv/src/test/cpp/regression/main.cpp:2079). Without these the
# fitness number reflects a zero-wait fantasy bus that's impossible to
# build, and an apples-to-apples comparison with public CoreMark numbers
# becomes meaningless (cf. our V0 hitting "2.87 CM/MHz" zero-wait vs
# "2.21" with stalls; the latter is the honest microarch number).
COREMARK_SIM_FLAGS = ["--bench", "--istall", "--dstall"]
# Min seed successes needed to call placement "good". V0 runs 3 nextpnr
# seeds; if 2+ fail to place, the design is fragile/bloated/broken and
# the median of a single survivor is not a real signal.
MIN_SUCCESSFUL_SEEDS = 2

def parse_iterations(worktree: str) -> int:
    """Read ITERATIONS from portme.h so we can't get out of sync with the ELF."""
    path = Path(worktree).resolve() / PORTME_H
    if not path.exists():
        raise RuntimeError(f"{path} not found — can't determine CoreMark ITERATIONS")
    m = re.search(r'^\s*#\s*define\s+ITERATIONS\s+(\d+)', path.read_text(), re.MULTILINE)
    if not m:
        raise RuntimeError(f"ITERATIONS not found in {path}")
    return int(m.group(1))

async def run_seed(seed: int, worktree: str, outdir: str, env: dict | None = None) -> dict:
    # cwd=worktree: nextpnr_run.sh reads generated/synth.json and fpga/constraints/*
    # as worktree-relative paths. Without cwd, it would read from the caller's cwd
    # (e.g., repo root) and we'd score the wrong design.
    proc = await asyncio.create_subprocess_exec(
        "bash", NEXTPNR_SCRIPT, str(seed), outdir,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=Path(worktree).resolve(),
        env=env,
    )
    stdout, stderr = await proc.communicate()
    output = (stdout + stderr).decode()

    # Take the LAST "Max frequency" line: nextpnr prints intermediate estimates
    # during place-and-route plus a final post-routing value. The final one is
    # authoritative — an earlier match can be pessimistic (pre-route estimate)
    # or optimistic (pre-placement estimate).
    matches = re.findall(r'Max frequency[^\d]+([\d.]+)\s+MHz', output)
    fmax = float(matches[-1]) if matches else None

    # Treat a non-zero exit from nextpnr (passed through pipefail in the
    # shell script) as placement failure even if it printed a frequency
    # line during a partial run.
    placement_failed = (proc.returncode != 0) or (fmax is None)

    return {
        'seed': seed,
        'fmax_mhz': fmax if not placement_failed else None,
        'log': output,
        'returncode': proc.returncode,
        'placement_failed': placement_failed,
    }

async def _run_all_seeds(worktree: str, generated_dir: str = "generated", env: dict | None = None) -> list:
    tasks = [run_seed(s, worktree, f"{generated_dir}/pnr_seed{s}", env=env) for s in SEEDS]
    return await asyncio.gather(*tasks)

def run_coremark_ipc(worktree: str, sim_bin: str | None = None, env: dict | None = None) -> dict:
    """Run CoreMark on Verilator sim, return {iter_per_cycle, completed, cycles, iterations}.
    Completion is only trusted when the simulation retired an ebreak — otherwise the
    benchmark hit maxcycles without completing and the cycle count is meaningless."""
    worktree_path = Path(worktree).resolve()
    if sim_bin is None:
        sim_bin = str(worktree_path / "test/cosim/obj_dir/cosim_sim")
    elf     = str(worktree_path / "bench/programs/coremark.elf")
    # 50M cycle ceiling: 2K CoreMark with ITERATIONS=10 + iStall+dStall
    # needs ~5M cycles. 50M gives 10x headroom for slower candidates.
    try:
        result = subprocess.run(
            [sim_bin, elf, "50000000"] + COREMARK_SIM_FLAGS,
            capture_output=True, text=True, timeout=600, env=env
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': f'coremark_harness_error: {e}'}
    lines = [l for l in result.stdout.splitlines() if l.strip()]
    if len(lines) < 2:
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': 'no output from sim'}

    # Last line is the ebreak/maxcycles marker; second-to-last is the final retirement.
    try:
        marker = json.loads(lines[-1])
        last_retirement = json.loads(lines[-2])
    except json.JSONDecodeError as e:
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': f'malformed sim output: {e}'}

    if not marker.get('ebreak', False):
        # Benchmark ran out of cycles before finishing. Score 0 — don't credit
        # a hung CPU with whatever cycle count it happened to reach.
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': 'maxcycles_hit_before_ebreak'}

    # OOB sticky flag from the sim: if the CPU addressed outside 1 MiB at any
    # point during this run, the cycle count we're about to divide by is tainted
    # by silently-wrapped memory accesses. Treat as a benchmark failure — the
    # same rule cosim applies, so a CPU that produces a correct CRC via aliased
    # memory doesn't earn a fitness score.
    if marker.get('oob', False):
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': 'oob_memory_access'}

    uart = marker.get('uart', '')
    iterations = parse_iterations(worktree)
    valid, reason = validate_coremark_uart(uart, iterations)
    if not valid:
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': reason}

    # Bracketed cycles (start_time..stop_time) are the contract per
    # bench/programs/coremark/baremetal/core_portme.c's start/stop_time.
    # If both markers aren't present, the run is INVALID for fitness
    # scoring — DO NOT fall back to total elapsed: a CPU/MMIO bug that
    # drops 0x10000100/0x10000104 writes would silently get scored on
    # init+CRC-printing overhead too.
    if not marker.get('bench_bracketed', False):
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': f'bench_markers_missing: '
                          f'start={marker.get("bench_start_cycle")} '
                          f'stop={marker.get("bench_stop_cycle")}'}
    elapsed_cycles = int(marker['bench_stop_cycle']) - int(marker['bench_start_cycle'])
    if elapsed_cycles <= 0:
        return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                'reason': f'invalid_bench_bracket: start={marker.get("bench_start_cycle")} stop={marker.get("bench_stop_cycle")}'}
    ipc = iterations / elapsed_cycles
    return {'completed': True, 'iter_per_cycle': ipc, 'cycles': elapsed_cycles,
            'iterations': iterations, 'bracketed_cycles': True}

def _uart_int(uart: str, pattern: str, base: int = 10):
    m = re.search(pattern, uart)
    return int(m.group(1), base) if m else None

def validate_coremark_uart(uart: str, iterations: int) -> tuple:
    """Require CoreMark's own validation and exact expected CRC markers,
    including crcfinal (the fingerprint over the entire run)."""
    if 'Correct operation validated' not in uart:
        if 'Cannot validate operation' in uart:
            return False, f'coremark_unvalidated_seed_or_size: {uart[-500:]}'
        if 'ERROR' in uart or 'Errors detected' in uart:
            return False, f'coremark_reported_error: {uart[-500:]}'
        return False, f'coremark_validation_marker_missing: {uart[-500:]}'

    checks = [
        ('seedcrc',   _uart_int(uart, r'seedcrc\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crclist',   _uart_int(uart, r'\[0\]crclist\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crcmatrix', _uart_int(uart, r'\[0\]crcmatrix\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crcstate',  _uart_int(uart, r'\[0\]crcstate\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crcfinal',  _uart_int(uart, r'\[0\]crcfinal\s*:\s*0x([0-9a-fA-F]+)', 16)),
    ]
    for name, got in checks:
        expected = COREMARK_EXPECTED[name]
        if got != expected:
            return False, f'coremark_{name}_mismatch: expected 0x{expected:04x}, got {got}'

    reported_iterations = _uart_int(uart, r'Iterations\s*:\s*(\d+)')
    if reported_iterations != iterations:
        return False, f'coremark_iterations_mismatch: expected {iterations}, got {reported_iterations}'
    return True, None

def run_fpga_eval(worktree: str, target: str | None = None) -> dict:
    """
    Args:
      worktree: path to the repo root (or worktree).
      target:   optional core name (e.g. 'v1'). When set, injects
                RTL_DIR=cores/<target>/rtl into the yosys env and resolves
                generated/ and cosim_sim from cores/<target>/ instead of
                the repo-root defaults.

    Returns:
      {'placement_failed': True}         — all PnR seeds failed
      {'bench_failed': True, ...}        — bench didn't reach ebreak
      {
        'fmax_mhz': float,               — median of successful seeds
        'ipc_coremark': float,           — iter/cycle
        'fitness': float,                — CoreMark score: iter/sec = fmax_hz * iter/cycle
        'cycles': int, 'iterations': int,
        'seeds': [float, ...],
        'lut4': int, 'ff': int,
      }
    """
    worktree = str(Path(worktree).resolve())
    env = os.environ.copy()
    if target is not None:
        env["RTL_DIR"] = str(Path(worktree) / "cores" / target / "rtl")

    generated_dir = (
        str(Path(worktree) / "cores" / target / "generated") if target is not None else "generated"
    )
    sim_bin = (
        str(Path(worktree) / "cores" / target / "obj_dir" / "cosim_sim")
        if target is not None
        else None
    )

    seed_results = asyncio.run(_run_all_seeds(worktree, generated_dir, env=env))
    successful   = [r for r in seed_results if not r['placement_failed']]
    all_fmax     = [r['fmax_mhz'] for r in successful]
    seeds_log    = [r.get('fmax_mhz') for r in seed_results]

    if len(successful) < MIN_SUCCESSFUL_SEEDS:
        # 0-of-3 or 1-of-3 placements is itself a quality signal: the
        # design is unroutable or fragile. Single-seed luck is not a
        # fitness score we'll commit to.
        return {
            'placement_failed': True,
            'seeds': seeds_log,
            'successful_seeds': len(successful),
            'min_required':     MIN_SUCCESSFUL_SEEDS,
        }

    fmax_median = statistics.median(all_fmax)
    cm          = run_coremark_ipc(worktree, sim_bin, env=env)

    if not cm['completed']:
        return {
            'bench_failed': True,
            'reason': cm.get('reason', 'unknown'),
            'fmax_mhz': round(fmax_median, 2),
            'seeds': all_fmax,
            'placement_failed': False,
        }

    fitness = fmax_median * cm['iter_per_cycle'] * 1_000_000  # iter/sec

    log    = successful[-1]['log']
    lut4_m = re.search(r'LUT4:\s+(\d+)/',  log)
    ff_m   = re.search(r'\bDFF:\s+(\d+)/', log)

    return {
        'fmax_mhz':      round(fmax_median, 2),
        'ipc_coremark':  round(cm['iter_per_cycle'], 6),
        'fitness':       round(fitness, 2),
        'cycles':        cm['cycles'],
        'iterations':    cm['iterations'],
        'seeds':         all_fmax,
        'lut4':          int(lut4_m.group(1)) if lut4_m else 0,
        'ff':            int(ff_m.group(1))   if ff_m   else 0,
        'placement_failed': False,
    }

if __name__ == '__main__':
    import sys
    result = run_fpga_eval(
        sys.argv[1] if len(sys.argv) > 1 else '.',
        sys.argv[2] if len(sys.argv) > 2 else None,
    )
    print(json.dumps(result, indent=2))
