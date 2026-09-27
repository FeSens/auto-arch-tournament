"""Runs 3 nextpnr seeds in parallel, returns median Fmax and CoreMark iter/sec."""
import asyncio, os, re, json, subprocess, statistics
from pathlib import Path

from tools.eval.formal import read_nret
from tools.eval._subprocess import run_pgroup


def _build_synth_env(worktree, target: str | None,
                     base_env: dict | None = None) -> dict:
    """Build the env for `yosys -c fpga/scripts/synth.tcl`.

    Reads cores/<target>/core.yaml's `nret` field (defaults to 2). When
    nret=1, injects BENCH=fpga/core_bench_si.sv so synth.tcl reads the
    single-issue FPGA wrapper (only `_0` RVFI ports) instead of the
    default dual-channel core_bench.sv. nret=2 leaves BENCH unset and
    synth.tcl falls back to fpga/core_bench.sv.
    """
    worktree_path = Path(worktree).resolve()
    env = dict(base_env) if base_env is not None else os.environ.copy()
    if target is None:
        return env
    env["RTL_DIR"] = f"cores/{target}/rtl"
    env["GEN_DIR"] = f"cores/{target}/generated"
    nret = read_nret(worktree_path / "cores" / target / "core.yaml")
    if nret == 1:
        env["BENCH"] = "fpga/core_bench_si.sv"
    return env

SEEDS = [1, 2, 3]
# Fmax is scored over (perturbation, seed) pairs. Perturbation k adds an
# unused k-assign module to synthesis (k=0: the netlist `make` built);
# neutral changes like this move a design's Fmax by far more than nextpnr
# seeds do (EXP-2026-09-27-v2-placement-noise), so one netlist is one
# draw. Set from that calibration; see research/v2/NOTES.md.
PERTURBATIONS = [(0, 1), (0, 2), (0, 3)]
# The final champion's Fmax for the headline score is measured afresh on
# perturbations and seeds the loop never used: the loop's number was
# selected for being high (winner's curse) and rests on fewer draws.
FINAL_PERTURBATIONS = [(100 + i, 100 + i) for i in range(1, 16)]
# Per-seed wall-clock cap on nextpnr. Without it a design that never
# routes hangs the rep with no outcome recorded (V1: one seed took ~45 min
# and blocked the FPGA gate). A seed that hits the cap counts as a failed
# seed, the same as a placement failure.
NEXTPNR_TIMEOUT_SEC = 2700
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
        start_new_session=True,  # own process group, so a timeout kills nextpnr too
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(),
                                                timeout=NEXTPNR_TIMEOUT_SEC)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, 9)
        except ProcessLookupError:
            pass
        await proc.wait()
        return {
            'seed': seed,
            'fmax_mhz': None,
            'log': f'nextpnr timeout after {NEXTPNR_TIMEOUT_SEC}s',
            'returncode': None,
            'placement_failed': True,
            'timed_out': True,
        }
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


def pad_module(k: int) -> str:
    """The unused module behind perturbation k (identical to the
    calibration driver's)."""
    body = "\n".join(f"  assign y[{i}] = a[{i}] ^ a[{(i + 1) % 32}];" for i in range(k))
    return ("module zz_calib_pad(input logic [31:0] a, output logic [31:0] y);\n"
            f"{body}\nendmodule\n")


async def _synth_variant(k: int, worktree: str, generated_dir: str,
                         synth_env: dict) -> tuple[str, str | None]:
    """Synthesize perturbation k into <generated_dir>/var<k>/synth.json.
    Returns (dir, error or None). k=0 reuses the netlist `make` built."""
    if k == 0:
        return generated_dir, None
    vdir = f"{generated_dir}/var{k}"
    root = Path(worktree).resolve()
    (root / vdir).mkdir(parents=True, exist_ok=True)
    (root / vdir / "zz_calib_pad.sv").write_text(pad_module(k))
    env = {**synth_env, "GEN_DIR": vdir, "SYNTH_PAD": f"{vdir}/zz_calib_pad.sv"}
    proc = await asyncio.create_subprocess_exec(
        "yosys", "-q", "-l", f"{vdir}/synth.log", "-c", "fpga/scripts/synth.tcl",
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        cwd=root, env=env, start_new_session=True)
    _, err = await proc.communicate()
    if proc.returncode != 0:
        return vdir, f"synth var{k} failed: {err.decode(errors='replace')[-300:]}"
    return vdir, None


async def _run_perturbations(worktree: str, generated_dir: str, env: dict,
                             synth_env: dict, pairs=None) -> list:
    pairs = PERTURBATIONS if pairs is None else pairs
    ks = sorted({k for k, _ in pairs})
    synths = dict(zip(ks, await asyncio.gather(
        *(_synth_variant(k, worktree, generated_dir, synth_env) for k in ks))))

    async def one(k, seed):
        vdir, err = synths[k]
        if err:
            r = {'seed': seed, 'fmax_mhz': None, 'log': err, 'returncode': None,
                 'placement_failed': True}
        else:
            r = await run_seed(seed, worktree, f"{vdir}/pnr_seed{seed}", env=env)
        return {**r, 'perturbation': k}
    return await asyncio.gather(*(one(k, s) for k, s in pairs))

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
        result = run_pgroup(
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

def measure_fmax(worktree: str, target: str, pairs=None) -> dict:
    """Fmax only (no CoreMark), median over pairs; every pair re-synthesizes,
    so no pair may use perturbation 0. Returns {'fmax_mhz': float | None,
    'pairs': [[k, seed, fmax], ...], 'placed': int}."""
    pairs = FINAL_PERTURBATIONS if pairs is None else pairs
    if any(k == 0 for k, _ in pairs):
        raise ValueError("measure_fmax pairs must all be perturbed (k > 0)")
    worktree = str(Path(worktree).resolve())
    env = os.environ.copy()
    synth_env = _build_synth_env(worktree, target, base_env=env)
    res = asyncio.run(_run_perturbations(worktree, f"cores/{target}/generated", env,
                                         synth_env, pairs=pairs))
    ok = [r['fmax_mhz'] for r in res if not r['placement_failed']]
    enough = len(ok) >= -(-2 * len(res) // 3)
    return {'fmax_mhz': round(statistics.median(ok), 2) if enough else None,
            'pairs': [[r['perturbation'], r['seed'], r.get('fmax_mhz')] for r in res],
            'placed': len(ok)}


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
      {'bench_failed': True, ...}        — bench didn't reach ebreak, or
                                           reason 'fpga_report_unparsed: ...'
                                           when LUT4/DFF counts are missing
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

    synth_env = _build_synth_env(worktree, target, base_env=os.environ.copy())
    seed_results = asyncio.run(_run_perturbations(worktree, generated_dir, env, synth_env))
    successful   = [r for r in seed_results if not r['placement_failed']]
    all_fmax     = [r['fmax_mhz'] for r in successful]
    seeds_log    = [r.get('fmax_mhz') for r in seed_results]
    # Same 2-of-3 bar as V1, scaled to the number of pairs.
    min_ok = -(-2 * len(seed_results) // 3)

    if len(successful) < min_ok:
        # 0-of-3 or 1-of-3 placements is itself a quality signal: the
        # design is unroutable or fragile. Single-seed luck is not a
        # fitness score we'll commit to.
        return {
            'placement_failed': True,
            'seeds': seeds_log,
            'successful_seeds': len(successful),
            'min_required':     min_ok,
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

    # Area of the netlist `make` built (perturbation 0); cell counts do not
    # depend on the placement seed.
    area_run = next((r for r in successful if r.get('perturbation', 0) == 0), successful[0])
    log    = area_run['log']
    lut4_m = re.search(r'LUT4:\s+(\d+)/',  log)
    ff_m   = re.search(r'\bDFF:\s+(\d+)/', log)
    # Memory and DSP cells are not LUT4s; report them so area is not
    # understated for designs that move logic into RAM or DSP blocks.
    def _cells(name: str) -> int:
        m = re.search(rf'\b{name}:\s+(\d+)/', log)
        return int(m.group(1)) if m else 0
    if not (lut4_m and ff_m):
        # Never substitute 0: with a LUT target set, 0 LUT4 is the best
        # possible area score, so a nextpnr log-format change would turn
        # every hypothesis into a "win". Fail loudly instead.
        missing = [n for n, m in (('LUT4', lut4_m), ('DFF', ff_m)) if not m]
        return {
            'bench_failed': True,
            'reason': (f'fpga_report_unparsed: no {"/".join(missing)} count in '
                       f'nextpnr log (seed {area_run["seed"]})'),
            'fmax_mhz': round(fmax_median, 2),
            'seeds': all_fmax,
            'placement_failed': False,
        }

    return {
        'fmax_mhz':      round(fmax_median, 2),
        'ipc_coremark':  round(cm['iter_per_cycle'], 6),
        'fitness':       round(fitness, 2),
        'cycles':        cm['cycles'],
        'iterations':    cm['iterations'],
        'seeds':         all_fmax,
        'perturbations': [[r['perturbation'], r['seed'], r.get('fmax_mhz')]
                          for r in seed_results],
        'lut4':          int(lut4_m.group(1)),
        'lutram':        _cells('RAM16SDP4'),
        'bsram':         _cells('BSRAM'),
        'dsp':           sum(_cells(n) for n in ('MULT36X36', 'MULT18X18', 'MULT9X9',
                                                 'MULTALU36X18', 'MULTALU18X18',
                                                 'MULTADDALU18X18', 'ALU54D')),
        'ff':            int(ff_m.group(1)),
        'placement_failed': False,
    }

if __name__ == '__main__':
    import sys
    result = run_fpga_eval(
        sys.argv[1] if len(sys.argv) > 1 else '.',
        sys.argv[2] if len(sys.argv) > 2 else None,
    )
    print(json.dumps(result, indent=2))
