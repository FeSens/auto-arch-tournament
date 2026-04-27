"""Runs 3 nextpnr seeds in parallel, returns median Fmax and CoreMark iter/sec."""
import asyncio, re, json, subprocess, statistics
from pathlib import Path

SEEDS = [1, 2, 3]
NEXTPNR_SCRIPT = "fpga/scripts/nextpnr_run.sh"
PORTME_H = "bench/programs/coremark/baremetal/core_portme.h"
COREMARK_EXPECTED = {
    'seedcrc': 0x8a02,
    'crclist': 0xd4b0,
    'crcmatrix': 0xbe52,
    'crcstate': 0x5e47,
}

def parse_iterations(worktree: str) -> int:
    """Read ITERATIONS from portme.h so we can't get out of sync with the ELF."""
    path = Path(worktree).resolve() / PORTME_H
    if not path.exists():
        raise RuntimeError(f"{path} not found — can't determine CoreMark ITERATIONS")
    m = re.search(r'^\s*#\s*define\s+ITERATIONS\s+(\d+)', path.read_text(), re.MULTILINE)
    if not m:
        raise RuntimeError(f"ITERATIONS not found in {path}")
    return int(m.group(1))

async def run_seed(seed: int, worktree: str, outdir: str) -> dict:
    # cwd=worktree: nextpnr_run.sh reads generated/synth.json and fpga/constraints/*
    # as worktree-relative paths. Without cwd, it would read from the caller's cwd
    # (e.g., repo root) and we'd score the wrong design.
    proc = await asyncio.create_subprocess_exec(
        "bash", NEXTPNR_SCRIPT, str(seed), outdir,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=Path(worktree).resolve(),
    )
    stdout, stderr = await proc.communicate()
    output = (stdout + stderr).decode()

    # Take the LAST "Max frequency" line: nextpnr prints intermediate estimates
    # during place-and-route plus a final post-routing value. The final one is
    # authoritative — an earlier match can be pessimistic (pre-route estimate)
    # or optimistic (pre-placement estimate).
    matches = re.findall(r'Max frequency[^\d]+([\d.]+)\s+MHz', output)
    fmax = float(matches[-1]) if matches else None

    return {
        'seed': seed,
        'fmax_mhz': fmax,
        'log': output,
        'placement_failed': fmax is None,
    }

async def _run_all_seeds(worktree: str) -> list:
    tasks = [run_seed(s, worktree, f"generated/pnr_seed{s}") for s in SEEDS]
    return await asyncio.gather(*tasks)

def run_coremark_ipc(worktree: str) -> dict:
    """Run CoreMark on Verilator sim, return {iter_per_cycle, completed, cycles, iterations}.
    Completion is only trusted when the simulation retired an ebreak — otherwise the
    benchmark hit maxcycles without completing and the cycle count is meaningless."""
    worktree_path = Path(worktree).resolve()
    sim_bin = str(worktree_path / "test/cosim/obj_dir/cosim_sim")
    elf     = str(worktree_path / "bench/programs/coremark.elf")
    # 500M cycle ceiling: canonical 6K CoreMark needs ~247M cycles for 100 iter
    # at ~0.85 IPC. 500M gives ~2× headroom for slower candidates.
    try:
        result = subprocess.run(
            [sim_bin, elf, "500000000", "--bench"],
            capture_output=True, text=True, timeout=600
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

    # Prefer bench-bracketed cycles (start_time..stop_time) over total elapsed.
    # The bracketed window excludes program init, CoreMark's core_init_* setup,
    # and CRC printing from the timing — matching the canonical CoreMark score
    # definition. Fall back to total elapsed only if the harness didn't get
    # both markers (e.g., older ELF, bench crashed mid-run).
    if marker.get('bench_bracketed', False):
        elapsed_cycles = int(marker['bench_stop_cycle']) - int(marker['bench_start_cycle'])
        if elapsed_cycles <= 0:
            return {'completed': False, 'iter_per_cycle': 0.0, 'cycles': 0, 'iterations': 0,
                    'reason': f'invalid_bench_bracket: start={marker.get("bench_start_cycle")} stop={marker.get("bench_stop_cycle")}'}
        bracketed = True
    else:
        elapsed_cycles = last_retirement.get('cycle', 0) + 1
        bracketed = False
    ipc = iterations / elapsed_cycles if elapsed_cycles > 0 else 0.0
    return {'completed': True, 'iter_per_cycle': ipc, 'cycles': elapsed_cycles,
            'iterations': iterations, 'bracketed_cycles': bracketed}

def _uart_int(uart: str, pattern: str, base: int = 10):
    m = re.search(pattern, uart)
    return int(m.group(1), base) if m else None

def validate_coremark_uart(uart: str, iterations: int) -> tuple:
    """Require CoreMark's own validation and exact expected CRC markers."""
    if 'Correct operation validated' not in uart:
        if 'Cannot validate operation' in uart:
            return False, f'coremark_unvalidated_seed_or_size: {uart[-500:]}'
        if 'ERROR' in uart or 'Errors detected' in uart:
            return False, f'coremark_reported_error: {uart[-500:]}'
        return False, f'coremark_validation_marker_missing: {uart[-500:]}'

    checks = [
        ('seedcrc', _uart_int(uart, r'seedcrc\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crclist', _uart_int(uart, r'\[0\]crclist\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crcmatrix', _uart_int(uart, r'\[0\]crcmatrix\s*:\s*0x([0-9a-fA-F]+)', 16)),
        ('crcstate', _uart_int(uart, r'\[0\]crcstate\s*:\s*0x([0-9a-fA-F]+)', 16)),
    ]
    for name, got in checks:
        expected = COREMARK_EXPECTED[name]
        if got != expected:
            return False, f'coremark_{name}_mismatch: expected 0x{expected:04x}, got {got}'

    reported_iterations = _uart_int(uart, r'Iterations\s*:\s*(\d+)')
    if reported_iterations != iterations:
        return False, f'coremark_iterations_mismatch: expected {iterations}, got {reported_iterations}'
    return True, None

def run_fpga_eval(worktree: str) -> dict:
    """
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
    seed_results = asyncio.run(_run_all_seeds(worktree))
    successful   = [r for r in seed_results if not r['placement_failed']]
    all_fmax     = [r['fmax_mhz'] for r in successful]

    if not successful:
        return {'placement_failed': True, 'seeds': [None, None, None]}

    fmax_median = statistics.median(all_fmax)
    cm          = run_coremark_ipc(worktree)

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
    result = run_fpga_eval(sys.argv[1] if len(sys.argv)>1 else '.')
    print(json.dumps(result, indent=2))
