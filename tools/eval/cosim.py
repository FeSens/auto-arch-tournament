"""Runs Verilator cosim for all bench ELFs. Returns structured pass/fail.

Correctness is gated in two stages:
  1. Full RVFI trace cosim for selftest and any other small ELF — every
     retirement is diffed against the Python reference ISS.
  2. CoreMark CRC validation via the sim's UART capture — full-trace cosim
     of coremark.elf is skipped because the Python reference is ~10⁴× slower
     than Verilator (would take 30+ minutes per candidate). Instead we run
     the sim in --bench mode and verify its UART matches the canonical CRCs
     with `validate_coremark_uart` (the same check run_fpga_eval uses). This
     catches any CPU bug that affects CoreMark output without the full trace
     overhead.
"""
import os, subprocess, json, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

BENCH_DIR = Path("bench/programs")

def run_one(elf: Path, sim_bin: str, worktree: str, env: dict | None = None) -> dict:
    """Run cosim for a single ELF using the run_cosim script."""
    try:
        worktree_path = Path(worktree).resolve()
        result = subprocess.run(
            [sys.executable, str(worktree_path / "test/cosim/run_cosim.py"),
             sim_bin, str(elf)],
            capture_output=True, text=True, timeout=120, cwd=worktree_path, env=env
        )
        if result.returncode == 0:
            return {'passed': True, 'elf': elf.name}
        else:
            detail = (result.stdout + result.stderr)[-2000:]
            return {'passed': False, 'elf': elf.name, 'field': 'divergence', 'detail': detail}
    except subprocess.TimeoutExpired:
        return {'passed': False, 'elf': elf.name, 'field': 'timeout'}
    except Exception as e:
        return {'passed': False, 'elf': elf.name, 'field': 'error', 'detail': str(e)}


def run_coremark_crc(coremark_elf: Path, sim_bin: str, worktree: str, env: dict | None = None) -> dict:
    """Run coremark.elf on the sim and validate UART-reported CRC.

    Full-trace cosim would take >30 min; the CRC guard is sensitive to any
    computational bug since CoreMark's CRC is computed over every algorithm's
    working set. This is the same validation run_fpga_eval applies and
    cross-checks it at the cosim stage too.
    """
    # Late import so fpga.py's asyncio/statistics deps aren't required for
    # projects that only run cosim.
    from tools.eval.fpga import validate_coremark_uart, parse_iterations
    # Stall flags match the orchestrator's fitness eval so the CRC validation
    # gate exercises the same workload that fpga.py scores. See
    # tools/eval/fpga.py:COREMARK_SIM_FLAGS for the rationale.
    try:
        result = subprocess.run(
            [sim_bin, str(coremark_elf), "50000000",
             "--bench", "--istall", "--dstall"],
            capture_output=True, text=True, timeout=600,
            cwd=Path(worktree).resolve(), env=env
        )
    except subprocess.TimeoutExpired:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'timeout'}
    except Exception as e:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'error', 'detail': str(e)}

    # rc==3 means ebreak reached but the CPU made an out-of-bounds memory
    # access during the run — surface that explicitly instead of letting the
    # silent-wraparound CRC path accidentally pass.
    if result.returncode == 3:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'oob_access',
                'detail': result.stdout[-1000:]}

    lines = [l for l in result.stdout.splitlines() if l.strip()]
    if not lines:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'no_output'}
    try:
        marker = json.loads(lines[-1])
    except json.JSONDecodeError as e:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'malformed_marker',
                'detail': f'{e}: {lines[-1][:500]}'}
    if not marker.get('ebreak', False):
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'no_ebreak',
                'detail': 'maxcycles hit before ebreak'}
    if marker.get('oob', False):
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'oob_access',
                'detail': marker.get('uart', '')[-500:]}
    iterations = parse_iterations(worktree)
    valid, reason = validate_coremark_uart(marker.get('uart', ''), iterations)
    if not valid:
        return {'passed': False, 'elf': coremark_elf.name, 'field': 'crc_mismatch',
                'detail': reason}
    return {'passed': True, 'elf': coremark_elf.name}


def run_cosim(worktree: str, target: str | None = None) -> dict:
    """
    Args:
      worktree: path to the repo root (or worktree).
      target:   optional core name (e.g. 'v1'). When set, resolves
                cosim_sim from cores/<target>/obj_dir/cosim_sim instead of
                the default test/cosim/obj_dir/cosim_sim, and injects
                RTL_DIR/OBJ_DIR into the subprocess env.

    Returns:
      {'passed': True, 'elfs_tested': N}
      {'passed': False, 'failed_elf': name, 'detail': {...}}
    """
    worktree_path = Path(worktree).resolve()
    env = os.environ.copy()
    if target is not None:
        env["RTL_DIR"] = str(worktree_path / "cores" / target / "rtl")
        env["OBJ_DIR"] = str(worktree_path / "cores" / target / "obj_dir")
    obj_dir = Path(env.get("OBJ_DIR", "test/cosim/obj_dir"))
    if not obj_dir.is_absolute():
        obj_dir = worktree_path / obj_dir
    sim_bin = str(obj_dir / "cosim_sim")

    # Split ELFs into full-trace cosim vs CRC-validated coremark.
    all_elfs = list((worktree_path / "bench/programs").glob("*.elf"))
    trace_elfs = [p for p in all_elfs if p.name != "coremark.elf"]
    coremark   = next((p for p in all_elfs if p.name == "coremark.elf"), None)

    if not trace_elfs and coremark is None:
        return {'passed': False, 'failed_elf': 'none', 'detail': 'no ELFs found'}

    # 1. Full-trace cosim of small ELFs (parallel).
    with ThreadPoolExecutor() as pool:
        futures = {pool.submit(run_one, elf, sim_bin, worktree, env): elf for elf in trace_elfs}
        for future in as_completed(futures):
            result = future.result()
            if not result['passed']:
                return {
                    'passed': False,
                    'failed_elf': result['elf'],
                    'detail': result,
                }

    # 2. CoreMark CRC validation (sequential — runs the 500M-cycle sim).
    if coremark is not None:
        cm_result = run_coremark_crc(coremark, sim_bin, worktree, env)
        if not cm_result['passed']:
            return {
                'passed': False,
                'failed_elf': cm_result['elf'],
                'detail': cm_result,
            }

    tested = len(trace_elfs) + (1 if coremark else 0)
    return {'passed': True, 'elfs_tested': tested}


if __name__ == '__main__':
    result = run_cosim(
        sys.argv[1] if len(sys.argv) > 1 else '.',
        sys.argv[2] if len(sys.argv) > 2 else None,
    )
    print(json.dumps(result, indent=2))
