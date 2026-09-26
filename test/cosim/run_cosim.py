#!/usr/bin/env python3
"""Drives both reference and Verilator model, diffs RVFI output."""
import json, subprocess, sys
from pathlib import Path

def run_verilator(sim_bin, elf, maxcycles=50_000_000, timeout=120):
    result = subprocess.run([sim_bin, elf, str(maxcycles)],
                            capture_output=True, text=True, timeout=timeout)
    trace = []
    for line in result.stdout.splitlines():
        if line.strip():
            trace.append(json.loads(line))
    # returncode: 0 = ebreak + in-bounds, 2 = maxcycles hit, 3 = ebreak + OOB access.
    # Only rc==0 means clean completion; rc==3 signals the CPU generated an
    # out-of-bounds memory address that used to silently wrap.
    completed = result.returncode == 0 and bool(trace) and trace[-1].get('insn') == 0x00100073
    stderr_msg = result.stderr[-2000:]
    if result.returncode == 3:
        stderr_msg = (stderr_msg + '\n[oob_access detected during simulation]').strip()
    return trace, completed, result.returncode, stderr_msg

def run_reference(elf, max_insns=10_000_000):
    sys.path.insert(0, str(Path(__file__).parent))
    from reference import RV32IM
    cpu = RV32IM(); cpu.load_elf(elf)
    trace = []
    for _ in range(max_insns):
        r = cpu.step()
        if r is None:
            return trace, False, 'reference_invalid_or_unsupported_instruction'
        trace.append(r)
        if r['insn'] == 0x00100073:
            return trace, True, None
    return trace, False, 'reference_max_insns_without_ebreak'

def _mismatch(i, ref, field, expected, got):
    return {'passed': False, 'divergence_at': i,
            'insn': hex(ref['insn']), 'pc': hex(ref['pc']),
            'field': field, 'expected': hex(expected), 'got': hex(got)}

def compare(ref_trace, sim_trace, ref_completed=True, sim_completed=True,
            ref_reason=None, sim_returncode=0, sim_stderr=''):
    for i, (ref, sim) in enumerate(zip(ref_trace, sim_trace)):
        # Direct-equality RVFI fields. trap/halt/intr/mode/ixl are included
        # so that any future divergence (e.g., CPU starts asserting trap or
        # misreports privilege mode) surfaces immediately instead of hiding
        # inside fields cosim used to ignore.
        for rf, sf in [('order', 'order'), ('pc', 'pc_rdata'), ('npc', 'pc_wdata'), ('insn', 'insn'),
                       ('rd', 'rd_addr'), ('rd_wdata', 'rd_wdata'),
                       ('rs1', 'rs1_addr'), ('rs1_rdata', 'rs1_rdata'),
                       ('rs2', 'rs2_addr'), ('rs2_rdata', 'rs2_rdata'),
                       ('trap', 'trap'), ('halt', 'halt'), ('intr', 'intr'),
                       ('mode', 'mode'), ('ixl', 'ixl')]:
            if ref.get(rf, 0) != sim.get(sf, 0):
                return _mismatch(i, ref, rf, ref.get(rf, 0), sim.get(sf, 0))
        # RVFI ALIGNED_MEM convention: mem_addr is word-aligned; byte offset is
        # encoded in the shifted byte-lane mask. Reference ISS reports raw byte
        # address + unshifted width mask (1 byte / 3 half / 15 word). Normalize.
        byte_off   = ref.get('mem_addr', 0) & 3
        ref_addr   = ref.get('mem_addr', 0) & ~3
        ref_rmask  = (ref.get('mem_rmask', 0) << byte_off) & 0xF
        ref_wmask  = (ref.get('mem_wmask', 0) << byte_off) & 0xF
        ref_wdata  = (ref.get('mem_wdata', 0) << (byte_off * 8)) & 0xFFFFFFFF
        ref_rdata  = (ref.get('mem_rdata', 0) << (byte_off * 8)) & 0xFFFFFFFF
        # Always require ref/sim mem_*mask to agree: that's the source of
        # truth for whether a memory op happened at all.
        if ref_rmask != sim.get('mem_rmask', 0):
            return _mismatch(i, ref, 'mem_rmask', ref_rmask, sim.get('mem_rmask', 0))
        if ref_wmask != sim.get('mem_wmask', 0):
            return _mismatch(i, ref, 'mem_wmask', ref_wmask, sim.get('mem_wmask', 0))
        # mem_addr only matters when at least one mask is non-zero. With
        # both masks 0 (no mem op — common on traps), an addr discrepancy
        # is meaningless garbage. The trap field itself is checked above.
        if (ref_rmask | ref_wmask) and ref_addr != sim.get('mem_addr', 0):
            return _mismatch(i, ref, 'mem_addr', ref_addr, sim.get('mem_addr', 0))
        # Only compare rdata bytes that are actually read. The reference keeps
        # sub-word values unshifted; RVFI ALIGNED_MEM reports the full memory word.
        if ref_rmask:
            mask_bits = sum(0xFF << (j * 8) for j in range(4) if (ref_rmask >> j) & 1)
            if (ref_rdata & mask_bits) != (sim.get('mem_rdata', 0) & mask_bits):
                return _mismatch(i, ref, 'mem_rdata',
                                 ref_rdata & mask_bits, sim.get('mem_rdata', 0) & mask_bits)
        # Only compare wdata bytes that are actually written.
        if ref_wmask:
            mask_bits = sum(0xFF << (j * 8) for j in range(4) if (ref_wmask >> j) & 1)
            if (ref_wdata & mask_bits) != (sim.get('mem_wdata', 0) & mask_bits):
                return _mismatch(i, ref, 'mem_wdata',
                                 ref_wdata & mask_bits, sim.get('mem_wdata', 0) & mask_bits)
    if not ref_completed:
        return {'passed': False, 'divergence_at': len(ref_trace),
                'field': 'reference_completion', 'reason': ref_reason or 'reference_incomplete'}
    if not sim_completed:
        return {'passed': False, 'divergence_at': len(sim_trace),
                'field': 'sim_completion', 'returncode': sim_returncode,
                'reason': sim_stderr or 'sim_did_not_retire_ebreak'}
    if len(ref_trace) != len(sim_trace):
        return {'passed': False, 'divergence_at': min(len(ref_trace),len(sim_trace)),
                'field': 'retirement_count',
                'expected': len(ref_trace), 'got': len(sim_trace)}
    return {'passed': True, 'retired': len(ref_trace)}

if __name__ == '__main__':
    sim_bin, elf = sys.argv[1], sys.argv[2]
    try:
        ref, ref_completed, ref_reason = run_reference(elf)
        sim, sim_completed, sim_returncode, sim_stderr = run_verilator(sim_bin, elf)
        result = compare(ref, sim, ref_completed, sim_completed,
                         ref_reason, sim_returncode, sim_stderr)
    except (json.JSONDecodeError, subprocess.TimeoutExpired, OSError) as e:
        result = {'passed': False, 'field': 'harness_error', 'detail': str(e)}
    print(json.dumps(result))
    sys.exit(0 if result['passed'] else 1)
