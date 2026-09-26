"""End-to-end pipeline tests for rtl/core.sv.

Drives a minimal Python-side imem/dmem against the core's combinational
fetch/load model and captures RVFI retirements. Covers the §8 phase-2
acceptance set: forwarding (EX->EX, MEM->EX), branches, JAL, JALR,
SW+LW roundtrip, load-use stall, and the trap discipline (illegal /
ECALL trap, EBREAK does NOT trap).

Also covers the multi-cycle DIV/DIVU/REM/REMU interlock: result
forwarding to dependents, back-to-back divides, operands forwarded at
launch (incl. from a LW), divides around branches/jumps, and the same
programs under imem/dmem bus stalls (the formal wrapper ties both
ready signals high, so stalls are only exercised here and in cosim).

Also covers IF's stall-only replay store: on a cycle where imem refuses
the fetch, IF serves the current PC from the words it has already
fetched. The harness drives a poison word on imemData whenever
iready=0, so an instruction that retires correctly after a refused
fetch can only have come from the replay store.

Also covers the fetch-time BRANCH/JAL prediction (bimodal BHT, JAL
always taken, misaligned targets never predicted): every retirement of
each predictor program is compared against a small golden ISS, so a
wrong-path retirement, a lost mispredict recovery or a bad rd value
fails exactly, and the same programs are replayed under bus stalls.

Also covers the ID/EX bubble discipline: a bubble clears only the
control half of ID/EX, so the killed instruction's payload (a SW, a
JALR, a DIV) must stay inert.

Also covers MEM's stall-only D-side: a store the dmem bus refuses is
posted to a 1-entry store buffer and retires, and a load of a word the
direct-mapped load cache holds completes on a refused cycle. The
harness drives POISON on dmemRData whenever dready=0, so a load that
retires correctly after a refused MEM cycle can only have come from the
cache. After EBREAK it clocks a few zero-wait cycles so a posted store
drains into the returned dmem.

The GPRs have no reset, so every run starts by zeroing them in software
(CLEAR_REGS).
"""
from __future__ import annotations

import itertools
import random
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from _helpers import run_cocotb


# ── RV32I instruction encoder helpers ──────────────────────────────────────
def _r(funct7, rs2, rs1, funct3, rd, opcode):
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _i(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) \
         | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def _s(imm, rs2, rs1, funct3, opcode):
    imm_hi = (imm >> 5) & 0x7F
    imm_lo = imm & 0x1F
    return (imm_hi << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | (imm_lo << 7) | (opcode & 0x7F)


def _b(imm, rs2, rs1, funct3, opcode):
    # imm is a 13-bit signed number; bit 0 is implicitly zero.
    b12  = (imm >> 12) & 1
    b105 = (imm >> 5)  & 0x3F
    b41  = (imm >> 1)  & 0xF
    b11  = (imm >> 11) & 1
    return (b12 << 31) | (b105 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
         | ((funct3 & 0x7) << 12) | (b41 << 8) | (b11 << 7) | (opcode & 0x7F)


def _j(imm, rd, opcode):
    # 21-bit signed imm; bit 0 implicit zero.
    b20    = (imm >> 20) & 1
    b101   = (imm >> 1)  & 0x3FF
    b11    = (imm >> 11) & 1
    b1912  = (imm >> 12) & 0xFF
    return (b20 << 31) | (b101 << 21) | (b11 << 20) | (b1912 << 12) \
         | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def ADDI(rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b000, rd, 0b0010011)
def XORI(rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b100, rd, 0b0010011)
def ADD (rd, rs1, rs2): return _r(0, rs2, rs1, 0b000, rd, 0b0110011)
def LW  (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b010, rd, 0b0000011)
def SW  (rs2, rs1, imm): return _s(imm & 0xFFF, rs2, rs1, 0b010, 0b0100011)
def BEQ (rs1, rs2, imm): return _b(imm, rs2, rs1, 0b000, 0b1100011)
def BNE (rs1, rs2, imm): return _b(imm, rs2, rs1, 0b001, 0b1100011)
def BLT (rs1, rs2, imm): return _b(imm, rs2, rs1, 0b100, 0b1100011)
def BGE (rs1, rs2, imm): return _b(imm, rs2, rs1, 0b101, 0b1100011)
def BLTU(rs1, rs2, imm): return _b(imm, rs2, rs1, 0b110, 0b1100011)
def BGEU(rs1, rs2, imm): return _b(imm, rs2, rs1, 0b111, 0b1100011)
def MUL (rd, rs1, rs2): return _r(1, rs2, rs1, 0b000, rd, 0b0110011)
def DIV (rd, rs1, rs2): return _r(1, rs2, rs1, 0b100, rd, 0b0110011)
def DIVU(rd, rs1, rs2): return _r(1, rs2, rs1, 0b101, rd, 0b0110011)
def REM (rd, rs1, rs2): return _r(1, rs2, rs1, 0b110, rd, 0b0110011)
def REMU(rd, rs1, rs2): return _r(1, rs2, rs1, 0b111, rd, 0b0110011)
def LB  (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b000, rd, 0b0000011)
def LH  (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b001, rd, 0b0000011)
def LBU (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b100, rd, 0b0000011)
def LHU (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b101, rd, 0b0000011)
def SB  (rs2, rs1, imm): return _s(imm & 0xFFF, rs2, rs1, 0b000, 0b0100011)
def SH  (rs2, rs1, imm): return _s(imm & 0xFFF, rs2, rs1, 0b001, 0b0100011)
def LUI (rd, imm20):     return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | 0b0110111
def JAL (rd, imm):       return _j(imm, rd, 0b1101111)
def JALR(rd, rs1, imm):  return _i(imm & 0xFFF, rs1, 0b000, rd, 0b1100111)
def NOP():               return ADDI(0, 0, 0)        # = 0x00000013
def EBREAK():            return 0x00100073
def ECALL():             return 0x00000073


# ── Harness ────────────────────────────────────────────────────────────────
# Driven on imemData on every cycle the imem bus refuses the fetch
# (iready=0). It decodes as JAL x29, so a leaked poison word redirects
# and writes x29 instead of vanishing silently. Also driven on dmemRData
# on every cycle the dmem bus refuses (dready=0).
POISON = 0xDEADBEEF

# mem_stage's load cache geometry: two word addresses DC_STRIDE bytes
# apart share a cache index (different tag).
DC_IDX_W = int(re.search(
    r"localparam\s+int\s+DC_IDX_W\s*=\s*(\d+)",
    (Path(__file__).resolve().parent.parent / "rtl" / "mem_stage.sv").read_text(),
).group(1))
DC_STRIDE = 4 << DC_IDX_W

# The GPRs have no reset (reg_file.sv), so every _run first retires one
# ADDI xN, x0, 0 per register: each program then starts from the
# all-zero register file the checks and the golden ISS assume, and a
# replayed program cannot see the previous run's values.
CLEAR_REGS = [ADDI(r, 0, 0) for r in range(1, 32)] + [EBREAK()]


async def _run(dut, program, dmem_init=None, max_cycles=200, ready=None,
               start_clock=True, fetch_log=None, dmem_log=None,
               clear_regs=True, drain=4):
    """Drive imem/dmem; capture RVFI retirements until EBREAK or max_cycles.

    imem is read combinationally each cycle from imemAddr; dmem similarly.
    Stores get applied to the Python-side dmem dict so subsequent loads
    see the new value.

    `ready` (optional) is a callable cycle -> (imem_ready, dmem_ready)
    giving the bus backpressure for each cycle, mirroring
    test/cosim/main.cpp: a store is only accepted on a cycle with
    dmem_ready=1. Default: zero-wait on both buses. On a cycle with
    imem_ready=0, imemData carries POISON instead of the addressed word;
    on a cycle with dmem_ready=0, dmemRData does.

    After the EBREAK retires, `drain` more zero-wait cycles are clocked
    (and applied to dmem) so a store still in MEM's store buffer lands.

    `fetch_log` (optional list) gets one (cycle, imemAddr, imem_ready)
    tuple appended per cycle up to the EBREAK; `dmem_log` one (cycle,
    dmemAddr, dmemREn, dmemWEn, dmem_ready) tuple per cycle, drain
    included.

    `clear_regs` zeroes x1..x31 first (CLEAR_REGS, then the reset below).

    Returns (retirements, dmem) where retirements is a list of dicts
    sampled on every cycle that rvfi_valid=1, up to the EBREAK.
    """
    imem = {i * 4: instr & 0xFFFFFFFF for i, instr in enumerate(program)}
    dmem = dict(dmem_init or {})
    retirements: list[dict] = []

    # Pass start_clock=False on the 2nd+ _run inside one cocotb test so
    # only one Clock driver toggles dut.clock.
    if start_clock:
        cocotb.start_soon(Clock(dut.clock, 10, "ns").start())

    if clear_regs:
        await _run(dut, CLEAR_REGS, max_cycles=100, start_clock=False,
                   clear_regs=False)

    dut.reset.value = 1
    dut.io_imemData.value = 0
    dut.io_dmemRData.value = 0
    # Zero-wait bus during reset; `ready` takes over once the loop runs.
    dut.io_imemReady.value = 1
    dut.io_dmemReady.value = 1
    for _ in range(3):
        await RisingEdge(dut.clock)

    # Deassert reset and prime the imem read for the first PC=0 fetch.
    dut.reset.value = 0
    dut.io_imemData.value = imem.get(0, EBREAK())

    ebreak_cycle = None
    for cycle in itertools.count():
        if ebreak_cycle is None and cycle == max_cycles:
            raise AssertionError(f"max_cycles={max_cycles} reached without EBREAK")
        if ebreak_cycle is not None and cycle > ebreak_cycle + drain:
            break
        draining = ebreak_cycle is not None

        await RisingEdge(dut.clock)
        await Timer(1, "ns")  # let combinational signals settle

        # Sample the post-edge state.
        ia        = int(dut.io_imemAddr.value)
        da        = int(dut.io_dmemAddr.value)
        wen       = int(dut.io_dmemWEn.value)
        rvfi_v    = int(dut.io_rvfi_valid_0.value) and not draining

        # Bus backpressure for this cycle. imemAddr / dmemAddr / dmemWEn
        # come straight from registers, so they don't depend on ready.
        iready, dready = ready(cycle) if ready and not draining else (1, 1)
        dut.io_imemReady.value = iready
        dut.io_dmemReady.value = dready
        if fetch_log is not None and not draining:
            fetch_log.append((cycle, ia, iready))
        if dmem_log is not None:
            dmem_log.append((cycle, da, int(dut.io_dmemREn.value), wen, dready))

        # Apply dmem write side effects (only if the bus accepts them).
        if wen and dready:
            wdata = int(dut.io_dmemWData.value)
            wa = da & ~3
            old = dmem.get(wa, 0)
            new = old
            for i in range(4):
                if (wen >> i) & 1:
                    bv = (wdata >> (i * 8)) & 0xFF
                    new = (new & ~(0xFF << (i * 8))) | (bv << (i * 8))
            dmem[wa] = new

        # Capture RVFI retirement.
        if rvfi_v:
            r = {
                "order":     int(dut.io_rvfi_order_0.value),
                "insn":      int(dut.io_rvfi_insn_0.value),
                "pc":        int(dut.io_rvfi_pc_rdata_0.value),
                "pc_next":   int(dut.io_rvfi_pc_wdata_0.value),
                "rd":        int(dut.io_rvfi_rd_addr_0.value),
                "rd_wdata":  int(dut.io_rvfi_rd_wdata_0.value),
                "rs1_addr":  int(dut.io_rvfi_rs1_addr_0.value),
                "rs1_rdata": int(dut.io_rvfi_rs1_rdata_0.value),
                "rs2_addr":  int(dut.io_rvfi_rs2_addr_0.value),
                "rs2_rdata": int(dut.io_rvfi_rs2_rdata_0.value),
                "trap":      int(dut.io_rvfi_trap_0.value),
                "mem_addr":  int(dut.io_rvfi_mem_addr_0.value),
                "mem_wmask": int(dut.io_rvfi_mem_wmask_0.value),
                "mem_wdata": int(dut.io_rvfi_mem_wdata_0.value),
                "mem_rmask": int(dut.io_rvfi_mem_rmask_0.value),
                "mem_rdata": int(dut.io_rvfi_mem_rdata_0.value),
                "cycle":     cycle,
            }
            retirements.append(r)
            if r["insn"] == EBREAK():
                ebreak_cycle = cycle

        # Drive this cycle's imem fetch and dmem read combinationally. A
        # refused access returns POISON: the core must not consume it.
        dut.io_imemData.value  = imem.get(ia & ~3, EBREAK()) if iready else POISON
        dut.io_dmemRData.value = dmem.get(da & ~3, 0) if dready else POISON

    return retirements, dmem


def _by_insn(retirements, insn):
    """Return all retirements matching a specific instruction word."""
    return [r for r in retirements if r["insn"] == insn]


# ── Tests ──────────────────────────────────────────────────────────────────
@cocotb.test()
async def forwarding_ex_to_ex(dut):
    """ADDI x1, x0, 5; ADDI x2, x1, 3 — back-to-back rs1 forward from EX/MEM."""
    program = [ADDI(1, 0, 5), ADDI(2, 1, 3), EBREAK()]
    rets, _ = await _run(dut, program)
    [r1] = _by_insn(rets, ADDI(1, 0, 5))
    [r2] = _by_insn(rets, ADDI(2, 1, 3))
    assert r1["rd"] == 1 and r1["rd_wdata"] == 5
    assert r2["rd"] == 2 and r2["rd_wdata"] == 8, (
        f"x2 should be x1+3=8 via EX->EX forward, got 0x{r2['rd_wdata']:08x}"
    )
    # Order must be strict +1.
    orders = [r["order"] for r in rets]
    assert orders == list(range(orders[0], orders[0] + len(rets)))


@cocotb.test()
async def forwarding_mem_to_ex(dut):
    """ADDI x1, x0, 5; NOP; ADDI x2, x1, 3 — rs1 forward from MEM/WB stage."""
    program = [ADDI(1, 0, 5), NOP(), ADDI(2, 1, 3), EBREAK()]
    rets, _ = await _run(dut, program)
    [r2] = _by_insn(rets, ADDI(2, 1, 3))
    assert r2["rd_wdata"] == 8


@cocotb.test()
async def load_use_stalls(dut):
    """SW x3 to mem; LW x1, 0(x0); ADD x2, x1, x4 — load-use must stall once.

    All immediates kept inside the signed 12-bit positive range so ADDI's
    sign-extension doesn't muddy the expected values.
    """
    program = [
        ADDI(3, 0, 0x123),     # x3 = 0x123
        ADDI(4, 0, 0x100),     # x4 = 0x100
        SW  (3, 0, 0),         # mem[0] = x3
        LW  (1, 0, 0),         # x1 = mem[0]; uses x1 next cycle -> stall
        ADD (2, 1, 4),         # x2 = x1 + x4 = 0x223
        EBREAK(),
    ]
    rets, dmem = await _run(dut, program)
    [r2] = _by_insn(rets, ADD(2, 1, 4))
    assert r2["rd_wdata"] == 0x223, f"x2 expected 0x223, got 0x{r2['rd_wdata']:08x}"
    assert dmem[0] == 0x123, f"mem[0] should hold 0x123, got {dmem[0]:#x}"


@cocotb.test()
async def branch_taken_skips(dut):
    """BEQ x0, x0, +8 — the wrong-path instruction must NOT retire at all,
    not merely retire with rd_wdata != 99. Asserting only the side effect
    would let a wrong-path retirement with rd=0 / trap=1 / different data
    pass silently."""
    program = [
        BEQ(0, 0, 8),          # PC=0;  taken; skip the next instr
        ADDI(1, 0, 99),        # PC=4;  SHOULD NEVER retire
        ADDI(2, 0, 42),        # PC=8;  branch target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    # Strict: no retirement should originate from PC=4.
    leaked = [r for r in rets if r["pc"] == 4]
    assert not leaked, f"wrong-path retirement leaked from PC=4: {leaked}"
    # Strict: no retirement carries the skipped instruction word at all.
    leaked_insn = [r for r in rets if r["insn"] == ADDI(1, 0, 99)]
    assert not leaked_insn, f"skipped instr ADDI x1,99 retired: {leaked_insn}"
    # Sanity: the target instruction and the EBREAK do retire, in order.
    pcs = [r["pc"] for r in rets]
    assert pcs == [0, 8, 12], f"unexpected retirement PC sequence: {pcs}"
    [r2] = _by_insn(rets, ADDI(2, 0, 42))
    assert r2["rd_wdata"] == 42


@cocotb.test()
async def jal_writes_pc_plus_4(dut):
    """JAL x1, +8; verify the wrong-path slot does not retire and x1=PC+4."""
    program = [
        JAL(1, 8),             # PC=0; x1 := 4; jump to PC=8
        ADDI(2, 0, 99),        # PC=4 — wrong-path; must not retire
        ADDI(3, 0, 42),        # PC=8 — target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    pcs = [r["pc"] for r in rets]
    assert pcs == [0, 8, 12], f"unexpected retirement PC sequence: {pcs}"
    [rj] = _by_insn(rets, JAL(1, 8))
    assert rj["rd"] == 1
    assert rj["rd_wdata"] == rj["pc"] + 4
    [r3] = _by_insn(rets, ADDI(3, 0, 42))
    assert r3["rd_wdata"] == 42


@cocotb.test()
async def jalr_target(dut):
    """ADDI x5,x0,12; JALR x1,x5,0; verify wrong-path slot doesn't retire."""
    program = [
        ADDI(5, 0, 12),        # PC=0;  x5 := 12
        JALR(1, 5, 0),         # PC=4;  jump to x5+0 = 12
        ADDI(6, 0, 99),        # PC=8;  wrong-path
        ADDI(7, 0, 42),        # PC=12; target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    pcs = [r["pc"] for r in rets]
    assert pcs == [0, 4, 12, 16], f"unexpected retirement PC sequence: {pcs}"
    [r7] = _by_insn(rets, ADDI(7, 0, 42))
    assert r7["rd_wdata"] == 42


@cocotb.test()
async def sw_lw_roundtrip(dut):
    """ADDI x1, 0xCAFE; SW x1; LW x2 — verify x2 sees the freshly stored word."""
    val = 0x123  # signed 12-bit fits
    program = [
        ADDI(1, 0, val),
        SW  (1, 0, 0),
        LW  (2, 0, 0),
        EBREAK(),
    ]
    rets, dmem = await _run(dut, program)
    [r2] = _by_insn(rets, LW(2, 0, 0))
    assert r2["rd_wdata"] == val, f"x2 expected {val:#x}, got 0x{r2['rd_wdata']:x}"
    assert dmem.get(0) == val


@cocotb.test()
async def illegal_traps(dut):
    """0xFFFFFFFF retires with rvfi_trap=1 and no rd write.

    Project convention: when reg_write=0 (which the decoder forces on
    illegal), rvfi_rd_addr and rvfi_rd_wdata are both reported as 0.
    This is one valid RVFI interpretation (the spec says "for
    instructions that do not write rd, the value is 0"). Some other
    cores report rd_addr = instr[11:7] regardless of trap and let the
    verifier ignore it on trap=1; both are accepted by riscv-formal.
    Our reference.py and DUT both follow the zeroed-on-trap convention,
    so cosim stays in lockstep."""
    program = [
        0xFFFFFFFF,
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    bad = next(r for r in rets if r["insn"] == 0xFFFFFFFF)
    assert bad["trap"] == 1
    assert bad["rd"] == 0
    assert bad["rd_wdata"] == 0


@cocotb.test()
async def ecall_traps(dut):
    """ECALL retires with rvfi_trap=1 (project-specific: only EBREAK is legal)."""
    program = [
        ECALL(),
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    [re] = _by_insn(rets, ECALL())
    assert re["trap"] == 1


@cocotb.test()
async def ebreak_does_not_trap(dut):
    """EBREAK retires with rvfi_trap=0 — this is the project-specific halt marker."""
    program = [EBREAK()]
    rets, _ = await _run(dut, program, max_cycles=20)
    [re] = _by_insn(rets, EBREAK())
    assert re["trap"] == 0, f"EBREAK should not trap; got trap={re['trap']}"


@cocotb.test()
async def rvfi_order_strictly_monotonic(dut):
    """A short stream must produce rvfi_order = 0,1,2,... with no gaps."""
    program = [
        ADDI(1, 0, 1),
        ADDI(2, 0, 2),
        ADDI(3, 0, 3),
        ADDI(4, 0, 4),
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    orders = [r["order"] for r in rets]
    assert orders == list(range(len(orders))), f"order not monotonic +1: {orders}"


# ── Multi-cycle DIV/REM interlock ─────────────────────────────────────────
M32 = 0xFFFFFFFF


def _s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def _div(a, b):
    sa, sb = _s32(a), _s32(b)
    if sb == 0:
        return M32
    if sa == -(1 << 31) and sb == -1:
        return 0x80000000
    q = abs(sa) // abs(sb)
    return (-q if (sa < 0) != (sb < 0) else q) & M32


def _rem(a, b):
    sa, sb = _s32(a), _s32(b)
    if sb == 0:
        return a & M32
    if sa == -(1 << 31) and sb == -1:
        return 0
    r = abs(sa) % abs(sb)
    return (-r if sa < 0 else r) & M32


def _divu(a, b): return M32 if b == 0 else (a // b) & M32
def _remu(a, b): return a & M32 if b == 0 else (a % b) & M32


def _check_order_and_pcs(rets, pcs):
    """Each expected PC retires exactly once, in order, with order +1."""
    got = [r["pc"] for r in rets]
    assert got == pcs, f"retirement PC sequence {got} != expected {pcs}"
    orders = [r["order"] for r in rets]
    assert orders == list(range(orders[0], orders[0] + len(rets))), (
        f"rvfi_order not strictly +1: {orders}"
    )
    for cur, nxt in zip(rets, rets[1:]):
        assert cur["pc_next"] == nxt["pc"], (
            f"pc={cur['pc']:#x}: pc_next {cur['pc_next']:#x} != next pc {nxt['pc']:#x}"
        )


def _one(rets, insn, pc=None):
    hits = [r for r in rets if r["insn"] == insn and (pc is None or r["pc"] == pc)]
    assert len(hits) == 1, f"insn 0x{insn:08x} retired {len(hits)} times"
    return hits[0]


def _expect(r, rd, rd_wdata, rs1_rdata=None, rs2_rdata=None):
    assert r["trap"] == 0, f"pc={r['pc']:#x} trapped"
    assert r["rd"] == rd, f"pc={r['pc']:#x}: rd {r['rd']} != {rd}"
    assert r["rd_wdata"] == rd_wdata & M32, (
        f"pc={r['pc']:#x}: rd_wdata 0x{r['rd_wdata']:08x} != 0x{rd_wdata & M32:08x}"
    )
    if rs1_rdata is not None:
        assert r["rs1_rdata"] == rs1_rdata & M32, (
            f"pc={r['pc']:#x}: rs1_rdata 0x{r['rs1_rdata']:08x} != 0x{rs1_rdata & M32:08x}"
        )
    if rs2_rdata is not None:
        assert r["rs2_rdata"] == rs2_rdata & M32, (
            f"pc={r['pc']:#x}: rs2_rdata 0x{r['rs2_rdata']:08x} != 0x{rs2_rdata & M32:08x}"
        )


# Programs are shared between the zero-wait checks and the bus-stall
# replays below.
PROG_DIV_FWD = [
    ADDI(1, 0, 100),       # 0
    ADDI(2, 0, 7),         # 4
    DIV (3, 1, 2),         # 8   rs1 via MEM/WB fwd, rs2 via EX/MEM fwd
    ADD (4, 3, 1),         # 12  div result via EX/MEM fwd
    ADD (5, 3, 2),         # 16  div result via MEM/WB fwd
    ADD (6, 0, 3),         # 20  div result via regfile
    EBREAK(),              # 24
]

PROG_DIV_B2B = [
    ADDI(1, 0, -100),      # 0
    ADDI(2, 0, 7),         # 4
    DIV (3, 1, 2),         # 8
    REM (4, 1, 2),         # 12  back-to-back, independent
    DIVU(5, 3, 2),         # 16  back-to-back, rs1 = DIV result (MEM/WB fwd)
    REMU(6, 5, 4),         # 20  back-to-back, rs1 = DIVU result (EX/MEM fwd)
    MUL (7, 6, 2),         # 24  single-cycle MUL right behind a divide
    EBREAK(),              # 28
]

PROG_DIV_LOAD = [
    ADDI(1, 0, 0x123),     # 0
    SW  (1, 0, 0),         # 4
    ADDI(2, 0, 5),         # 8
    LW  (3, 0, 0),         # 12
    DIV (4, 3, 2),         # 16  load-use: x3 via MEM/WB fwd of load data
    ADD (5, 4, 3),         # 20
    LW  (8, 0, 0),         # 24
    ADDI(9, 0, 1),         # 28
    REM (7, 8, 2),         # 32  x8 via MEM/WB fwd (load one slot ahead)
    SW  (7, 0, 4),         # 36  store the divide result
    LW  (10, 0, 4),        # 40
    EBREAK(),              # 44
]

PROG_DIV_CTRL = [
    ADDI(1, 0, 50),        # 0
    ADDI(2, 0, 6),         # 4
    BEQ (0, 0, 8),         # 8   taken -> 16
    ADDI(9, 0, 99),        # 12  wrong path
    DIV (3, 1, 2),         # 16  branch target
    JAL (0, 8),            # 20  -> 28
    ADDI(9, 0, 98),        # 24  wrong path
    REMU(4, 1, 2),         # 28  jump target
    JAL (5, 8),            # 32  x5 = 36 -> 40
    DIV (9, 1, 2),         # 36  wrong-path divide: must never start/retire
    DIVU(7, 5, 2),         # 40  rs1 = JAL link via EX/MEM fwd
    BNE (0, 0, 8),         # 44  not taken
    REM (8, 7, 4),         # 48  right behind a not-taken branch
    ADD (6, 3, 8),         # 52
    EBREAK(),              # 56
]


def _check_div_fwd(rets):
    _check_order_and_pcs(rets, [0, 4, 8, 12, 16, 20, 24])
    q = _div(100, 7)
    _expect(_one(rets, DIV(3, 1, 2)), 3, q, rs1_rdata=100, rs2_rdata=7)
    _expect(_one(rets, ADD(4, 3, 1)), 4, q + 100, rs1_rdata=q, rs2_rdata=100)
    _expect(_one(rets, ADD(5, 3, 2)), 5, q + 7, rs1_rdata=q, rs2_rdata=7)
    _expect(_one(rets, ADD(6, 0, 3)), 6, q, rs2_rdata=q)


def _check_div_b2b(rets):
    _check_order_and_pcs(rets, [0, 4, 8, 12, 16, 20, 24, 28])
    x1, x2 = (-100) & M32, 7
    x3 = _div(x1, x2)
    x4 = _rem(x1, x2)
    x5 = _divu(x3, x2)
    x6 = _remu(x5, x4)
    x7 = (x6 * x2) & M32
    assert (x3, x4) == (0xFFFFFFF2, 0xFFFFFFFE)
    _expect(_one(rets, DIV (3, 1, 2)), 3, x3, x1, x2)
    _expect(_one(rets, REM (4, 1, 2)), 4, x4, x1, x2)
    _expect(_one(rets, DIVU(5, 3, 2)), 5, x5, x3, x2)
    _expect(_one(rets, REMU(6, 5, 4)), 6, x6, x5, x4)
    _expect(_one(rets, MUL (7, 6, 2)), 7, x7, x6, x2)


def _check_div_load(rets, dmem):
    _check_order_and_pcs(rets, list(range(0, 48, 4)))
    x3 = 0x123
    x4 = _div(x3, 5)
    x7 = _rem(x3, 5)
    _expect(_one(rets, LW(3, 0, 0)), 3, x3)
    _expect(_one(rets, DIV(4, 3, 2)), 4, x4, rs1_rdata=x3, rs2_rdata=5)
    _expect(_one(rets, ADD(5, 4, 3)), 5, x4 + x3, rs1_rdata=x4, rs2_rdata=x3)
    _expect(_one(rets, REM(7, 8, 2)), 7, x7, rs1_rdata=x3, rs2_rdata=5)
    _expect(_one(rets, LW(10, 0, 4)), 10, x7)
    assert dmem.get(4) == x7


def _check_div_ctrl(rets):
    _check_order_and_pcs(rets, [0, 4, 8, 16, 20, 28, 32, 40, 44, 48, 52, 56])
    assert not [r for r in rets if r["pc"] in (12, 24, 36)], "wrong-path retired"
    x3 = _div(50, 6)
    x4 = _remu(50, 6)
    x7 = _divu(36, 6)
    x8 = _rem(x7, x4)
    _expect(_one(rets, DIV (3, 1, 2), pc=16), 3, x3, 50, 6)
    _expect(_one(rets, REMU(4, 1, 2)), 4, x4, 50, 6)
    _expect(_one(rets, JAL (5, 8)), 5, 36)
    _expect(_one(rets, DIVU(7, 5, 2)), 7, x7, 36, 6)
    _expect(_one(rets, REM (8, 7, 4)), 8, x8, x7, x4)
    _expect(_one(rets, ADD (6, 3, 8)), 6, x3 + x8, x3, x8)


@cocotb.test()
async def div_result_forwarding(dut):
    """DIV feeding dependents at EX/MEM, MEM/WB and regfile distance."""
    rets, _ = await _run(dut, PROG_DIV_FWD, max_cycles=300)
    _check_div_fwd(rets)


@cocotb.test()
async def div_back_to_back(dut):
    """DIV / REM / DIVU / REMU back to back, with chained dependencies."""
    rets, _ = await _run(dut, PROG_DIV_B2B, max_cycles=400)
    _check_div_b2b(rets)


@cocotb.test()
async def div_operand_from_load(dut):
    """DIV / REM whose operand is a LW result forwarded at launch."""
    rets, dmem = await _run(dut, PROG_DIV_LOAD, max_cycles=400)
    _check_div_load(rets, dmem)


@cocotb.test()
async def div_around_branches_and_jumps(dut):
    """Divides at branch/jump targets, behind a not-taken branch, fed by a
    JAL link value, and in a flushed wrong-path slot."""
    rets, _ = await _run(dut, PROG_DIV_CTRL, max_cycles=400)
    _check_div_ctrl(rets)


@cocotb.test()
async def div_done_held_by_dmem_stall(dut):
    """A LW stuck on the dmem bus for longer than the whole divide: the DIV
    behind it starts and finishes during the stall, then must hold its
    (sticky) result until EX/MEM can take it — retiring exactly once.
    The LW is a cache miss (first access after reset), so it can only
    complete once the bus serves it; a SW would be posted instead."""
    program = [
        ADDI(1, 0, 77),        # 0
        ADDI(2, 0, 5),         # 4
        LW  (6, 0, 8),         # 8   cold: stalls in MEM until cycle 70
        DIV (3, 1, 2),         # 12
        ADD (4, 3, 1),         # 16
        SW  (1, 0, 0),         # 20
        LW  (5, 0, 0),         # 24
        EBREAK(),              # 28
    ]
    rets, dmem = await _run(dut, program, dmem_init={8: 123}, max_cycles=300,
                            ready=lambda c: (1, 0 if c < 70 else 1))
    _check_order_and_pcs(rets, [0, 4, 8, 12, 16, 20, 24, 28])
    lw = _one(rets, LW(6, 0, 8))
    dv = _one(rets, DIV(3, 1, 2))
    assert lw["cycle"] > 70, "LW should have been held by the dmem stall"
    _expect(lw, 6, 123)
    _expect(dv, 3, 77 // 5, rs1_rdata=77, rs2_rdata=5)
    _expect(_one(rets, ADD(4, 3, 1)), 4, 77 // 5 + 77)
    _expect(_one(rets, LW(5, 0, 0)), 5, 77)
    assert dmem.get(0) == 77


def _random_ready(seed, p_stall=0.22):
    rng = random.Random(seed)
    table = {}

    def ready(cycle):
        if cycle not in table:
            table[cycle] = (int(rng.random() >= p_stall),
                            int(rng.random() >= p_stall))
        return table[cycle]
    return ready


def _arch(rets):
    """RVFI fields that must not depend on bus timing."""
    keys = ("order", "insn", "pc", "pc_next", "rd", "rd_wdata",
            "rs1_addr", "rs1_rdata", "rs2_addr", "rs2_rdata", "trap",
            "mem_addr", "mem_rmask", "mem_wmask")
    return [tuple(r[k] for k in keys) for r in rets]


@cocotb.test()
async def div_programs_under_bus_stalls(dut):
    """Replay every divide program under random ~22% imem + dmem stalls
    (cosim's model). The RVFI stream must match the zero-wait run exactly."""
    cases = [
        (PROG_DIV_FWD,  lambda r, m: _check_div_fwd(r)),
        (PROG_DIV_B2B,  lambda r, m: _check_div_b2b(r)),
        (PROG_DIV_LOAD, _check_div_load),
        (PROG_DIV_CTRL, lambda r, m: _check_div_ctrl(r)),
    ]
    first = True
    for idx, (prog, check) in enumerate(cases):
        base, _ = await _run(dut, prog, max_cycles=600, start_clock=first)
        first = False
        for seed in range(4):
            rets, dmem = await _run(dut, prog, max_cycles=1200,
                                    ready=_random_ready(1000 * idx + seed),
                                    start_clock=False)
            check(rets, dmem)
            assert _arch(rets) == _arch(base), (
                f"program {idx} seed {seed}: RVFI stream differs under stalls"
            )


# ── Stall-only I-fetch replay store ───────────────────────────────────────
# Countdown loop: LW/SW read-modify-write of one dmem word with a
# load-use dependent ADD, 20 iterations.
LOOP_HEAD = 16
PROG_REPLAY_LOOP = [
    ADDI(1, 0, 20),        # 0   x1 = trip count
    ADDI(2, 0, 0),         # 4   x2 = sum of running totals
    ADDI(3, 0, 0x40),      # 8   x3 = dmem base
    SW  (0, 3, 0),         # 12  mem[0x40] = 0
    LW  (4, 3, 0),         # 16  loop: x4 = mem[0x40]
    ADD (4, 4, 1),         # 20  load-use dependent: x4 += x1
    SW  (4, 3, 0),         # 24  mem[0x40] = x4
    ADD (2, 2, 4),         # 28  x2 += x4
    ADDI(1, 1, -1),        # 32  x1 -= 1
    BNE (1, 0, -20),       # 36  -> 16
    LW  (5, 3, 0),         # 40  x5 = mem[0x40]
    ADD (6, 5, 2),         # 44  x6 = x5 + x2
    EBREAK(),              # 48
]

# Two passes over a body with a JAL, a taken BEQ, a JAL +4 (redirect
# onto the PC IF is already fetching) and a LW + load-use dependent.
PROG_REPLAY_CTRL = [
    ADDI(1, 0, 2),         # 0   x1 = pass count
    ADDI(3, 0, 0x80),      # 4   x3 = dmem base
    ADDI(7, 0, 0),         # 8   x7 = accumulator
    JAL (5, 12),           # 12  body: -> 24, x5 = 16
    ADDI(7, 7, 100),       # 16  wrong path
    ADDI(7, 7, 200),       # 20  wrong path
    SW  (5, 3, 0),         # 24  JAL target: mem[0x80] = 16
    LW  (6, 3, 0),         # 28  x6 = 16
    ADD (7, 7, 6),         # 32  load-use dependent: x7 += x6
    BEQ (0, 0, 12),        # 36  taken -> 48
    ADDI(7, 7, 300),       # 40  wrong path
    ADDI(7, 7, 400),       # 44  wrong path
    JAL (9, 4),            # 48  BEQ target: -> 52, x9 = 52
    ADDI(1, 1, -1),        # 52  JAL target
    BNE (1, 0, -44),       # 56  -> 12
    ADD (8, 7, 9),         # 60  x8 = x7 + x9
    EBREAK(),              # 64
]
CTRL_REPLAYED = (24, 48, 52, 12, 32)  # redirect targets + load-use dependent


def _random_iready(seed, p_stall=0.22):
    """~22% random imem refusals; dmem zero-wait."""
    rng = random.Random(seed)
    table = {}

    def ready(cycle):
        if cycle not in table:
            table[cycle] = (int(rng.random() >= p_stall), 1)
        return table[cycle]
    return ready


def _random_dready(seed, p_stall=0.22):
    """~22% random dmem refusals; imem zero-wait."""
    rng = random.Random(seed)
    table = {}

    def ready(cycle):
        if cycle not in table:
            table[cycle] = (1, int(rng.random() >= p_stall))
        return table[cycle]
    return ready


def _refuse_seen(dut, dready=None):
    """imem refuses every fetch of an address it has already served once
    (dmem readiness from `dready`, default zero-wait). Every refused fetch
    must be a replay hit, so the core runs exactly as with iready=1."""
    served = set()

    def ready(cycle):
        ia = int(dut.io_imemAddr.value) & ~3
        iready = int(ia not in served)
        served.add(ia)
        return iready, dready(cycle)[1] if dready else 1
    return ready


def _flow(rets):
    return [(r["pc"], r["insn"], r["rd_wdata"]) for r in rets]


def _regs(rets):
    """Final architectural register state implied by the rd writes."""
    regs = {}
    for r in rets:
        if r["rd"]:
            regs[r["rd"]] = r["rd_wdata"]
    return regs


def _check_order(rets):
    orders = [r["order"] for r in rets]
    assert orders == list(range(len(rets))), f"rvfi_order not strictly +1: {orders}"


def _check_loop(rets, dmem):
    total, acc = 0, 0
    for x1 in range(20, 0, -1):
        total += x1
        acc += total
    regs = _regs(rets)
    assert regs[5] == total and regs[2] == acc and regs[6] == total + acc, regs
    assert dmem.get(0x40) == total
    assert not _by_insn(rets, POISON), "poison word retired"


def _check_ctrl(rets, dmem):
    body = [12, 24, 28, 32, 36, 48, 52, 56]
    _check_order_and_pcs(rets, [0, 4, 8] + body * 2 + [60, 64])
    regs = _regs(rets)
    assert regs[7] == 32 and regs[9] == 52 and regs[8] == 84, regs
    assert dmem.get(0x80) == 16
    assert not _by_insn(rets, POISON), "poison word retired"


def _refused(log):
    return [(c, ia) for c, ia, iready in log if not iready]


@cocotb.test()
async def replay_loop_under_istalls(dut):
    """Countdown loop under random ~22% imem refusals (and both buses):
    final registers, dmem and the retired (pc, insn, rd_wdata) stream
    equal the all-ready run; rvfi_order stays strictly +1."""
    base, base_dmem = await _run(dut, PROG_REPLAY_LOOP, max_cycles=400)
    _check_loop(base, base_dmem)
    _check_order(base)
    cases = [(_random_iready, s) for s in range(6)] + \
            [(_random_ready, 100 + s) for s in range(3)]
    for mk, seed in cases:
        log = []
        rets, dmem = await _run(dut, PROG_REPLAY_LOOP, max_cycles=800,
                                ready=mk(seed), start_clock=False,
                                fetch_log=log)
        assert _refused(log), f"seed {seed}: no refused fetches"
        _check_loop(rets, dmem)
        _check_order(rets)
        assert _flow(rets) == _flow(base), f"seed {seed}: retired stream differs"
        assert _arch(rets) == _arch(base), f"seed {seed}: RVFI stream differs"
        assert _regs(rets) == _regs(base) and dmem == base_dmem


@cocotb.test()
async def replay_hides_istalls_in_steady_state(dut):
    """Same loop, random imem refusals only. Once the body has been
    fetched, refused cycles still advance the PC linearly (replay hits),
    and every lost cycle is a refusal of a never-served address."""
    base, _ = await _run(dut, PROG_REPLAY_LOOP, max_cycles=400)
    for seed in range(4):
        log = []
        rets, dmem = await _run(dut, PROG_REPLAY_LOOP, max_cycles=800,
                                ready=_random_iready(seed), start_clock=False,
                                fetch_log=log)
        _check_loop(rets, dmem)
        # Steady state: from the first return to the loop head.
        first_back = next(i for i in range(1, len(log))
                          if log[i][1] == LOOP_HEAD and log[i - 1][1] != LOOP_HEAD
                          and any(ia > LOOP_HEAD for _, ia, _ in log[:i]))
        hidden = sum(1 for i in range(first_back, len(log) - 1)
                     if not log[i][2] and log[i + 1][1] == log[i][1] + 4)
        served, cold = set(), 0
        for _, ia, iready in log:
            if iready:
                served.add(ia)
            elif ia not in served:
                cold += 1
        refused = len(_refused(log))
        lost = rets[-1]["cycle"] - base[-1]["cycle"]
        assert hidden > 0, f"seed {seed}: no replay hit in steady state"
        assert 0 <= lost <= cold, (
            f"seed {seed}: lost {lost} cycles, only {cold} cold refusals")
        assert 4 * lost < refused, (
            f"seed {seed}: lost {lost} of {refused} refused cycles")


@cocotb.test()
async def replay_redirect_and_load_use_targets(dut):
    """imem refuses every address it has served before (poison data), so
    the second pass runs purely from the replay store: JAL / taken-BEQ /
    JAL+4 targets arrive on refused cycles right after the redirect, and
    the load-use dependent ADD is replayed across its stall. The run must
    be cycle-for-cycle identical to the all-ready run."""
    first = True
    for prog, check in ((PROG_REPLAY_CTRL, _check_ctrl),
                        (PROG_REPLAY_LOOP, _check_loop)):
        base, base_dmem = await _run(dut, prog, max_cycles=400,
                                     start_clock=first)
        first = False
        check(base, base_dmem)
        log = []
        rets, dmem = await _run(dut, prog, max_cycles=400,
                                ready=_refuse_seen(dut), start_clock=False,
                                fetch_log=log)
        check(rets, dmem)
        assert rets == base, "refuse-seen run differs from the all-ready run"
        assert 4 * len(_refused(log)) > len(log), "too few refused fetches"
        if prog is PROG_REPLAY_CTRL:
            replayed = {ia for _, ia in _refused(log)}
            missing = [a for a in CTRL_REPLAYED if a not in replayed]
            assert not missing, f"never served from replay: {missing}"

    # Same, composed with random dmem stalls: identical to the run with
    # the same dmem pattern and a zero-wait imem.
    for seed in range(3):
        base, _ = await _run(dut, PROG_REPLAY_CTRL, max_cycles=600,
                             ready=_random_dready(seed), start_clock=False)
        rets, dmem = await _run(dut, PROG_REPLAY_CTRL, max_cycles=600,
                                ready=_refuse_seen(dut, _random_dready(seed)),
                                start_clock=False)
        _check_ctrl(rets, dmem)
        assert rets == base, f"seed {seed}: refuse-seen + dstall run differs"


# ── Fetch-time BRANCH/JAL prediction ──────────────────────────────────────
def _sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


_LD_BYTES = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}   # LOAD funct3 -> access width
_ST_BYTES = {0: 1, 1: 2, 2: 4}               # STORE funct3 -> access width
_BR_COND = {                                 # BRANCH funct3 -> taken(a, b)
    0: lambda a, b: a == b,
    1: lambda a, b: a != b,
    4: lambda a, b: _s32(a) < _s32(b),
    5: lambda a, b: _s32(a) >= _s32(b),
    6: lambda a, b: a < b,
    7: lambda a, b: a >= b,
}


def _golden(program, max_steps=2000, dmem_init=None):
    """Reference retirement stream for the subset the predictor and
    D-side programs use: (pc, insn, rd, rd_wdata, pc_next, trap) per
    instruction, in the core's RVFI convention (rd/rd_wdata = 0 when
    nothing is written; a taken branch/jump to a misaligned target, or a
    load/store not aligned to its width, traps, writes nothing and falls
    through to pc+4)."""
    imem = {i * 4: w & M32 for i, w in enumerate(program)}
    regs = [0] * 32
    dmem = dict(dmem_init or {})
    pc, out = 0, []
    for _ in range(max_steps):
        insn = imem.get(pc, EBREAK())
        op, rd = insn & 0x7F, (insn >> 7) & 0x1F
        f3, f7 = (insn >> 12) & 7, insn >> 25
        a, b = regs[(insn >> 15) & 0x1F], regs[(insn >> 20) & 0x1F]
        iimm = _sx(insn >> 20, 12)
        simm = _sx(((insn >> 25) << 5) | ((insn >> 7) & 0x1F), 12)
        bimm = _sx((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11)
                   | (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
        jimm = _sx((((insn >> 31) & 1) << 20) | (((insn >> 12) & 0xFF) << 12)
                   | (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)
        wd, nxt, trap = None, (pc + 4) & M32, 0
        if insn == EBREAK():
            pass
        elif op == 0x13 and f3 == 0:
            wd = a + iimm
        elif op == 0x13 and f3 == 4:
            wd = a ^ (iimm & M32)
        elif op == 0x33 and f7 == 0 and f3 == 0:
            wd = a + b
        elif op == 0x33 and f7 == 1 and f3 == 4:
            wd = _div(a, b)
        elif op == 0x37:
            wd = insn & 0xFFFFF000
        elif op == 0x03 and f3 in _LD_BYTES:
            addr, n = (a + iimm) & M32, _LD_BYTES[f3]
            if addr % n:
                trap = 1
            else:
                v = (dmem.get(addr & ~3, 0) >> (8 * (addr & 3))) & ((1 << (8 * n)) - 1)
                wd = v if f3 & 4 else _sx(v, 8 * n) & M32
        elif op == 0x23 and f3 in _ST_BYTES:
            addr, n = (a + simm) & M32, _ST_BYTES[f3]
            if addr % n:
                trap = 1
            else:
                sh, lanes = 8 * (addr & 3), (1 << (8 * n)) - 1
                old = dmem.get(addr & ~3, 0)
                dmem[addr & ~3] = (old & ~(lanes << sh)) | ((b & lanes) << sh)
        elif op == 0x63 and f3 in _BR_COND:
            if _BR_COND[f3](a, b):
                nxt = (pc + bimm) & M32
        elif op == 0x6F:
            wd, nxt = pc + 4, (pc + jimm) & M32
        elif op == 0x67 and f3 == 0:
            wd, nxt = pc + 4, (a + iimm) & M32 & ~1
        else:
            raise AssertionError(f"_golden: unsupported insn 0x{insn:08x}")
        if nxt & 3:
            wd, nxt, trap = None, (pc + 4) & M32, 1
        if wd is not None and rd:
            regs[rd] = wd & M32
        else:
            rd, wd = 0, 0
        out.append((pc, insn, rd, wd & M32, nxt, trap))
        if insn == EBREAK():
            return out
        pc = nxt
    raise AssertionError("_golden: no EBREAK")


def _trace(rets):
    return [(r["pc"], r["insn"], r["rd"], r["rd_wdata"], r["pc_next"], r["trap"])
            for r in rets]


def _check_pred(rets, program, pcs, regs):
    """Exact retired stream (vs the golden ISS and a hand-written PC list),
    strict +1 rvfi_order from 0, no poison, and the final registers."""
    _check_order_and_pcs(rets, pcs)
    _check_order(rets)
    assert [(r["pc"], r["insn"]) for r in rets] == \
           [(pc, program[pc // 4] & M32) for pc in pcs]
    assert _trace(rets) == _golden(program), "retired stream != golden ISS"
    assert not _by_insn(rets, POISON), "poison word retired"
    final = _regs(rets)
    for rd, val in regs.items():
        assert final.get(rd) == val & M32, f"x{rd} = {final.get(rd)} != {val}"


# (1) Countdown loop: the back-edge BNE is taken PRED_ITERS-1 times and
# then falls through, so the last one is predicted taken and must
# recover to pc+4; the loop head it steered to must not retire.
PRED_ITERS     = 10
PRED_LOOP_HEAD = 8
PRED_LOOP_BNE  = 16
PROG_PRED_LOOP = [
    ADDI(1, 0, PRED_ITERS),  # 0   x1 = trip count
    ADDI(2, 0, 0),           # 4   x2 = 0
    ADDI(2, 2, 3),           # 8   loop: x2 += 3
    ADDI(1, 1, -1),          # 12  x1 -= 1
    BNE (1, 0, -8),          # 16  -> 8
    SW  (2, 0, 0x40),        # 20  fall-through: mem[0x40] = x2
    LW  (3, 0, 0x40),        # 24  x3 = mem[0x40]
    ADDI(4, 3, 1),           # 28  load-use dependent
    EBREAK(),                # 32
]
PRED_LOOP_PCS = [0, 4] + [8, 12, 16] * PRED_ITERS + [20, 24, 28, 32]
PRED_LOOP_REGS = {1: 0, 2: 3 * PRED_ITERS, 3: 3 * PRED_ITERS, 4: 3 * PRED_ITERS + 1}

# (2) Forward BEQ alternating taken / not-taken, taken first, so the
# counter ping-pongs 01 -> 10 -> 01 and the BEQ mispredicts both ways.
PRED_ALT_ITERS = 8
PROG_PRED_ALT = [
    ADDI(1, 0, PRED_ALT_ITERS),  # 0   x1 = trip count
    ADDI(2, 0, 1),           # 4   x2 = parity (first XORI -> 0: taken)
    ADDI(3, 0, 0),           # 8   x3 = iterations
    ADDI(4, 0, 0),           # 12  x4 = not-taken accumulator
    XORI(2, 2, 1),           # 16  loop: x2 ^= 1
    BEQ (2, 0, 12),          # 20  x2 == 0 -> 32
    ADDI(4, 4, 1),           # 24  not-taken path
    ADDI(4, 4, 16),          # 28  not-taken path
    ADDI(3, 3, 1),           # 32  BEQ target
    ADDI(1, 1, -1),          # 36
    BNE (1, 0, -24),         # 40  -> 16
    ADD (5, 3, 4),           # 44
    EBREAK(),                # 48
]
PRED_ALT_PCS = [0, 4, 8, 12] + sum(
    ([16, 20, 32, 36, 40] if i % 2 == 0 else [16, 20, 24, 28, 32, 36, 40]
     for i in range(PRED_ALT_ITERS)), []) + [44, 48]
PRED_ALT_REGS = {3: PRED_ALT_ITERS, 4: 17 * (PRED_ALT_ITERS // 2),
                 5: PRED_ALT_ITERS + 17 * (PRED_ALT_ITERS // 2)}

# (3) A BNE that consumes the LW right before it: the load-use stall
# holds the PC while the (predicted) branch sits in fetch.
PROG_PRED_LOADUSE = [
    ADDI(1, 0, 0x40),        # 0   x1 = dmem base
    ADDI(2, 0, 4),           # 4
    SW  (2, 1, 0),           # 8   mem[0x40] = 4
    ADDI(5, 0, 0),           # 12  x5 = accumulator
    LW  (3, 1, 0),           # 16  loop: x3 = mem[0x40]
    BNE (3, 0, 8),           # 20  load-use: x3 != 0 -> 28
    JAL (0, 24),             # 24  -> 48 (exit)
    ADDI(3, 3, -1),          # 28
    SW  (3, 1, 0),           # 32  mem[0x40] = x3
    ADDI(5, 5, 7),           # 36
    JAL (0, -24),            # 40  -> 16
    ADDI(9, 0, 99),          # 44  never reached
    ADD (6, 5, 3),           # 48  exit
    EBREAK(),                # 52
]
PRED_LOADUSE_PCS = [0, 4, 8, 12] + [16, 20, 28, 32, 36, 40] * 4 + [16, 20, 24, 48, 52]
PRED_LOADUSE_REGS = {3: 0, 5: 28, 6: 28}

# (4) JAL -> BNE back to back (and JAL -> JAL -> BNE on the back edge).
# The first JAL jumps over a poison word, which must never retire.
PROG_PRED_JAL_BNE = [
    ADDI(1, 0, 3),           # 0   x1 = trip count
    ADDI(2, 0, 0),           # 4
    JAL (5, 8),              # 8   loop: -> 16, x5 = 12
    POISON,                  # 12  jumped over
    BNE (1, 0, 8),           # 16  JAL target: x1 != 0 -> 24
    JAL (0, 16),             # 20  -> 36 (exit)
    ADDI(2, 2, 5),           # 24
    ADDI(1, 1, -1),          # 28
    JAL (0, -24),            # 32  -> 8
    ADD (6, 2, 5),           # 36  exit
    EBREAK(),                # 40
]
PRED_JAL_BNE_PCS = [0, 4] + [8, 16, 24, 28, 32] * 3 + [8, 16, 20, 36, 40]
PRED_JAL_BNE_REGS = {2: 15, 5: 12, 6: 27}

# (5) A BNE right behind a DIV: div_busy holds the PC for the whole
# divide while the (predicted-taken, from the 2nd pass on) BNE is in
# fetch.
PROG_PRED_DIV = [
    ADDI(1, 0, 3),           # 0   x1 = trip count
    ADDI(2, 0, 100),         # 4
    ADDI(3, 0, 7),           # 8
    ADDI(4, 0, 0),           # 12  x4 = accumulator
    DIV (5, 2, 3),           # 16  loop: x5 = x2 / 7
    BNE (1, 0, 8),           # 20  right behind the DIV: x1 != 0 -> 28
    JAL (0, 20),             # 24  -> 44 (exit)
    ADD (4, 4, 5),           # 28  x4 += x5
    ADDI(2, 2, 50),          # 32
    ADDI(1, 1, -1),          # 36
    JAL (0, -24),            # 40  -> 16
    ADD (6, 4, 5),           # 44  exit
    EBREAK(),                # 48
]
PRED_DIV_PCS = [0, 4, 8, 12] + [16, 20, 28, 32, 36, 40] * 3 + [16, 20, 24, 44, 48]
PRED_DIV_REGS = {4: 14 + 21 + 28, 5: 35, 6: 14 + 21 + 28 + 35}

# Misaligned targets (imm[1] set) are never predicted: a BNE whose
# counter has been trained taken and a JAL still trap and fall through.
PROG_PRED_MISALIGN = [
    ADDI(1, 0, 3),           # 0   x1 = trip count
    BNE (1, 0, 6),           # 4   loop: taken -> 10: trap, fall through
    JAL (5, 10),             # 8   -> 18: trap, x5 not written
    ADDI(1, 1, -1),          # 12
    BNE (1, 0, -12),         # 16  -> 4
    ADDI(2, 0, 7),           # 20
    EBREAK(),                # 24
]
PRED_MISALIGN_PCS = [0] + [4, 8, 12, 16] * 3 + [20, 24]
PRED_MISALIGN_REGS = {1: 0, 2: 7}

PRED_CASES = [
    (PROG_PRED_LOOP,     PRED_LOOP_PCS,     PRED_LOOP_REGS),
    (PROG_PRED_ALT,      PRED_ALT_PCS,      PRED_ALT_REGS),
    (PROG_PRED_LOADUSE,  PRED_LOADUSE_PCS,  PRED_LOADUSE_REGS),
    (PROG_PRED_JAL_BNE,  PRED_JAL_BNE_PCS,  PRED_JAL_BNE_REGS),
    (PROG_PRED_DIV,      PRED_DIV_PCS,      PRED_DIV_REGS),
    (PROG_PRED_MISALIGN, PRED_MISALIGN_PCS, PRED_MISALIGN_REGS),
]


def _loop_window(rets):
    """Cycles from the 2nd loop-head retirement to the last back-edge BNE
    retirement of PROG_PRED_LOOP (steady state: every PC already fetched,
    no memory op in the body)."""
    heads = [r for r in rets if r["pc"] == PRED_LOOP_HEAD]
    bnes = [r for r in rets if r["pc"] == PRED_LOOP_BNE]
    return bnes[-1]["cycle"] - heads[1]["cycle"]


# One retirement per cycle over iterations 2..PRED_ITERS: every taken
# back edge in the window was predicted (no bubble).
PRED_LOOP_WINDOW = 3 * (PRED_ITERS - 1) - 1
# Without prediction each of the PRED_ITERS-2 taken back edges inside
# the window costs one bubble.
PRED_LOOP_NOPRED = PRED_LOOP_WINDOW + (PRED_ITERS - 2)


@cocotb.test()
async def predict_loop_backedge(dut):
    """(1) Backward BNE taken N-1 times, then falling through: the
    predicted-taken last instance recovers to pc+4 with no wrong-path
    retirement, and steady-state taken back edges cost no bubble."""
    rets, dmem = await _run(dut, PROG_PRED_LOOP, max_cycles=300)
    _check_pred(rets, PROG_PRED_LOOP, PRED_LOOP_PCS, PRED_LOOP_REGS)
    assert dmem.get(0x40) == 3 * PRED_ITERS
    win = _loop_window(rets)
    assert win == PRED_LOOP_WINDOW, (
        f"steady-state loop took {win} cycles, expected {PRED_LOOP_WINDOW}")


@cocotb.test()
async def predict_forward_branch_alternating(dut):
    """(2) Forward BEQ alternating taken / not-taken: mispredicts in both
    directions recover to the right path."""
    rets, _ = await _run(dut, PROG_PRED_ALT, max_cycles=400)
    _check_pred(rets, PROG_PRED_ALT, PRED_ALT_PCS, PRED_ALT_REGS)


@cocotb.test()
async def predict_branch_behind_load_use(dut):
    """(3) BNE consuming the LW right before it: load-use stall while the
    predicted branch sits in fetch."""
    rets, dmem = await _run(dut, PROG_PRED_LOADUSE, max_cycles=400)
    _check_pred(rets, PROG_PRED_LOADUSE, PRED_LOADUSE_PCS, PRED_LOADUSE_REGS)
    assert dmem.get(0x40) == 0


@cocotb.test()
async def predict_jal_then_branch(dut):
    """(4) JAL -> BNE back to back; the JAL skips a poison word that must
    never retire, and the BNE's final mispredict recovers after a JAL."""
    rets, _ = await _run(dut, PROG_PRED_JAL_BNE, max_cycles=300)
    _check_pred(rets, PROG_PRED_JAL_BNE, PRED_JAL_BNE_PCS, PRED_JAL_BNE_REGS)
    assert not [r for r in rets if r["pc"] == 12], "jumped-over word retired"


@cocotb.test()
async def predict_branch_behind_div(dut):
    """(5) BNE right after a DIV: div_busy holds the PC while a predicted
    branch is in fetch; the branch retires once, after the divide."""
    rets, _ = await _run(dut, PROG_PRED_DIV, max_cycles=600)
    _check_pred(rets, PROG_PRED_DIV, PRED_DIV_PCS, PRED_DIV_REGS)


@cocotb.test()
async def predict_never_misaligned_target(dut):
    """A trained-taken BNE and a JAL whose targets are misaligned are not
    predicted: both trap, write nothing and fall through to pc+4. EX
    would recover from such a prediction too, so check it never happens:
    IF never fetches a misaligned address."""
    log = []
    rets, _ = await _run(dut, PROG_PRED_MISALIGN, max_cycles=300, fetch_log=log)
    _check_pred(rets, PROG_PRED_MISALIGN, PRED_MISALIGN_PCS, PRED_MISALIGN_REGS)
    traps = sorted({r["pc"] for r in rets if r["trap"]})
    assert traps == [4, 8], f"trapping PCs {traps}"
    assert all(r["rd"] == 0 for r in rets if r["trap"])
    bad = [(c, ia) for c, ia, _ in log if ia & 3]
    assert not bad, f"misaligned fetches (predicted misaligned target): {bad}"


@cocotb.test()
async def predict_loop_under_bus_stalls(dut):
    """(6) Loop (1) under seeded ~22% random imem + dmem stalls: the
    retirement stream equals the all-ready run, and the steady-state
    loop (replay hits, no memory op) keeps its no-bubble timing, below
    the prediction-free bound."""
    base, _ = await _run(dut, PROG_PRED_LOOP, max_cycles=300)
    for seed in range(6):
        log = []
        rets, dmem = await _run(dut, PROG_PRED_LOOP, max_cycles=800,
                                ready=_random_ready(500 + seed),
                                start_clock=False, fetch_log=log)
        assert _refused(log), f"seed {seed}: no refused fetches"
        _check_pred(rets, PROG_PRED_LOOP, PRED_LOOP_PCS, PRED_LOOP_REGS)
        assert _arch(rets) == _arch(base), f"seed {seed}: RVFI stream differs"
        assert dmem.get(0x40) == 3 * PRED_ITERS
        win = _loop_window(rets)
        assert win < PRED_LOOP_NOPRED, (
            f"seed {seed}: loop took {win} cycles, prediction-free bound "
            f"is {PRED_LOOP_NOPRED}")
        assert win == PRED_LOOP_WINDOW, f"seed {seed}: loop took {win} cycles"


@cocotb.test()
async def predict_programs_under_bus_stalls(dut):
    """Every predictor program under random imem-only and imem + dmem
    stalls, and with imem refusing every already-served address (pure
    replay): identical retirement stream to the all-ready run."""
    first = True
    for idx, (prog, pcs, regs) in enumerate(PRED_CASES):
        base, _ = await _run(dut, prog, max_cycles=600, start_clock=first)
        first = False
        runs = [_random_iready(2000 + 10 * idx), _random_ready(2001 + 10 * idx),
                _random_ready(2002 + 10 * idx), _refuse_seen(dut)]
        for k, ready in enumerate(runs):
            rets, _ = await _run(dut, prog, max_cycles=1500, ready=ready,
                                 start_clock=False)
            _check_pred(rets, prog, pcs, regs)
            assert _arch(rets) == _arch(base), (
                f"program {idx} run {k}: RVFI stream differs under stalls")


# ── ID/EX bubbles ─────────────────────────────────────────────────────────
# A bubble clears only ID/EX's control half (valid, pred_taken, reg_write,
# mem_read, mem_write, is_branch, is_jump, is_div); the data half keeps
# the killed instruction. On a load-use bubble that is the dependent
# instruction itself: here a SW, a JALR and a DIV. A mispredicted BEQ
# (first sighting, BHT weakly not-taken) adds a redirect bubble.
PROG_BUBBLE = [
    ADDI(3, 0, 0x40),        # 0   x3 = dmem base
    ADDI(1, 0, 7),           # 4
    SW  (1, 3, 0),           # 8   mem[0x40] = 7
    ADDI(2, 0, 60),          # 12
    SW  (2, 3, 8),           # 16  mem[0x48] = 60
    LW  (1, 3, 0),           # 20  x1 = 7
    SW  (1, 3, 4),           # 24  load-use: bubble holds this SW
    LW  (4, 3, 8),           # 28  x4 = 60
    JALR(5, 4, 0),           # 32  load-use: bubble holds this JALR; -> 60
] + [ADDI(6, 0, 1)] * 6 + [  # 36..56 wrong path
    LW  (7, 3, 4),           # 60  x7 = 7
    DIV (8, 7, 1),           # 64  load-use: bubble holds this DIV; x8 = 1
    BEQ (0, 0, 12),          # 68  taken, predicted not-taken -> 80
    SW  (3, 3, 12),          # 72  wrong path: must never write
    ADDI(9, 0, 99),          # 76  wrong path
    ADD (10, 8, 7),          # 80  x10 = 8
    EBREAK(),                # 84
]
BUBBLE_PCS = [0, 4, 8, 12, 16, 20, 24, 28, 32, 60, 64, 68, 80, 84]
BUBBLE_REGS = {1: 7, 2: 60, 3: 0x40, 4: 60, 5: 36, 7: 7, 8: 1, 10: 8}


def _accepted_dmem(log):
    """dmem accesses the bus accepted, in bus order: (kind, word addr)."""
    out = []
    for _, da, ren, wen, dready in log:
        if dready and wen:
            out.append(("w", da & ~3))
        if dready and ren:
            out.append(("r", da & ~3))
    return out


def _retired_dmem(rets):
    out = []
    for r in rets:
        if r["mem_wmask"]:
            out.append(("w", r["mem_addr"]))
        if r["mem_rmask"]:
            out.append(("r", r["mem_addr"]))
    return out


def _check_bus_order(accepted, retired):
    """The bus accesses are the retired loads/stores in program order,
    except that a load served by MEM's cache on a refused cycle never
    reaches the bus: every retired store is written exactly once, and
    no access is accepted that did not retire."""
    it = iter(retired)
    for acc in accepted:
        for ret in it:
            if ret == acc:
                break
            assert ret[0] == "r", (
                f"retired store {ret} never reached the bus: "
                f"accepted {accepted}, retired {retired}")
        else:
            raise AssertionError(
                f"bus access {acc} out of order or not retired: "
                f"accepted {accepted}, retired {retired}")
    rest = list(it)
    assert all(k == "r" for k, _ in rest), (
        f"retired stores {rest} never reached the bus")


@cocotb.test()
async def bubble_payload_is_inert(dut):
    """Load-use and mispredict bubbles carry a stale ID/EX payload but
    never write dmem, redirect, start a divide, write rd or retire: the
    retired stream matches the golden ISS, and the dmem accesses the bus
    accepted are exactly the retired loads/stores, in order (under dmem
    stalls, minus loads MEM's cache served). Zero-wait and under random
    imem + dmem stalls."""
    first = True
    for ready in (None, _random_ready(3000), _random_ready(3001)):
        log = []
        rets, dmem = await _run(dut, PROG_BUBBLE, max_cycles=800, ready=ready,
                                start_clock=first, dmem_log=log)
        first = False
        _check_pred(rets, PROG_BUBBLE, BUBBLE_PCS, BUBBLE_REGS)
        if ready is None:
            assert _accepted_dmem(log) == _retired_dmem(rets), (
                f"dmem accesses {_accepted_dmem(log)} != retired {_retired_dmem(rets)}")
        else:
            _check_bus_order(_accepted_dmem(log), _retired_dmem(rets))
        assert dmem == {0x40: 7, 0x44: 7, 0x48: 60}, dmem
        if ready is None:
            # The SW and the JALR really did take a load-use bubble.
            cyc = {r["pc"]: r["cycle"] for r in rets}
            assert cyc[24] - cyc[20] == 2 and cyc[32] - cyc[28] == 2, cyc


# ── Stall-only D-side: posted store buffer + load cache ────────────────────
def _arch_mem(rets):
    """_arch plus the memory data: the stored word, and the full loaded
    word (the cache holds whole architectural words, so a cache-served
    load reports the same mem_rdata as a bus load)."""
    return [a + (r["mem_wdata"] if r["mem_wmask"] else 0,
                 r["mem_rdata"] if r["mem_rmask"] else 0)
            for a, r in zip(_arch(rets), rets)]


def _cache_served(rets, dmem_log):
    """Loads that completed in MEM on a cycle the dmem bus refused: the
    load retiring at cycle c was in MEM during cycle c-1."""
    dready = {c: rdy for c, _, _, _, rdy in dmem_log}
    return [r for r in rets if r["mem_rmask"] and not dready[r["cycle"] - 1]]


def _random_ready_p(seed, p_istall, p_dstall):
    rng = random.Random(seed)
    table = {}

    def ready(cycle):
        if cycle not in table:
            table[cycle] = (int(rng.random() >= p_istall),
                            int(rng.random() >= p_dstall))
        return table[cycle]
    return ready


@cocotb.test()
async def posted_store_retires_during_dstall(dut):
    """A SW in MEM while the dmem bus refuses everything is posted: it
    retires (and so does the code behind it) long before the bus comes
    back, and its write lands exactly once, on the first ready cycle."""
    window = 50
    program = [
        ADDI(1, 0, 0x55),      # 0
        ADDI(3, 0, 0x40),      # 4
        SW  (1, 3, 0),         # 8   posted
        ADDI(2, 0, 7),         # 12
    ] + [NOP()] * 60 + [      # retire through the refused window
        ADD (4, 1, 2),
        EBREAK(),
    ]
    log = []
    rets, dmem = await _run(dut, program, max_cycles=300, dmem_log=log,
                            ready=lambda c: (1, 0 if c < window else 1))
    sw = _one(rets, SW(1, 3, 0))
    assert sw["cycle"] < 10, f"SW retired at cycle {sw['cycle']}, not posted"
    assert _one(rets, ADDI(2, 0, 7))["cycle"] < 10
    writes = [(c, da & ~3, wen) for c, da, _, wen, rdy in log if wen and rdy]
    assert writes == [(window, 0x40, 0xF)], f"bus writes {writes}"
    # While refused, the buffer kept presenting the store.
    held = [(da, wen) for c, da, _, wen, _ in log if sw["cycle"] <= c < window]
    assert held and all(h == (0x40, 0xF) for h in held), held
    assert dmem == {0x40: 0x55}, dmem
    _expect(_one(rets, ADD(4, 1, 2)), 4, 0x55 + 7)


# SW / LW, SB / LB, SH / LHU and SW / LW of one word back to back, then a
# partial store to an uncached word (invalidate path) and its reload.
PROG_ST_LD = [
    ADDI(3, 0, 0x40),        # 0   x3 = base
    ADDI(1, 0, 0x123),       # 4
    SW  (1, 3, 0),           # 8   posted, allocates the word
    LW  (2, 3, 0),           # 12  same word right behind: store bypass
    ADDI(4, 0, -1),          # 16
    SB  (4, 3, 1),           # 20  merges into the cached word
    LB  (5, 3, 1),           # 24  same word right behind: merged bypass
    LW  (6, 3, 0),           # 28  from the table
    ADDI(7, 0, 0x456),       # 32
    SH  (7, 3, 2),           # 36
    LHU (8, 3, 2),           # 40
    LW  (9, 3, 0),           # 44
    SB  (4, 3, 5),           # 48  partial store to uncached 0x44
    LW  (10, 3, 4),          # 52  miss: waits for the bus
    LBU (11, 3, 5),          # 56
    EBREAK(),                # 60
]
ST_LD_INIT = {0x44: 0x11223344}
ST_LD_REGS = {2: 0x123, 5: M32, 6: 0xFF23, 8: 0x456, 9: 0x0456FF23,
              10: 0x1122FF44, 11: 0xFF}


@cocotb.test()
async def store_merge_then_load_under_dstall(dut):
    """Stores and dependent loads of the same word with the dmem bus
    refusing 4 cycles in 5: loads right behind a store (lookahead
    bypass), byte/halfword merges into a cached word, and a partial store
    to an uncached word. Loads must complete from the cache on refused
    cycles (POISON on the bus) with the architectural value."""
    base, base_dmem = await _run(dut, PROG_ST_LD, dmem_init=ST_LD_INIT)
    assert _trace(base) == _golden(PROG_ST_LD, dmem_init=ST_LD_INIT)
    final = _regs(base)
    for rd, val in ST_LD_REGS.items():
        assert final.get(rd) == val, f"x{rd} = {final.get(rd):#x} != {val:#x}"
    assert base_dmem == {0x40: 0x0456FF23, 0x44: 0x1122FF44}, base_dmem
    for ready in (lambda c: (1, int(c % 5 == 4)),
                  lambda c: (1, int(c % 3 == 2)),
                  _random_ready_p(4000, 0.3, 0.7)):
        log = []
        rets, dmem = await _run(dut, PROG_ST_LD, dmem_init=ST_LD_INIT,
                                max_cycles=600, ready=ready,
                                start_clock=False, dmem_log=log)
        assert _arch_mem(rets) == _arch_mem(base), "RVFI stream differs"
        assert dmem == base_dmem, dmem
        served = {r["pc"] for r in _cache_served(rets, log)}
        assert served & {12, 24}, f"no bypassed load served on a refused cycle: {served}"
        assert 52 not in served, "the load after an invalidating store hit"
        _check_bus_order(_accepted_dmem(log), _retired_dmem(rets))


@cocotb.test()
async def cache_aliasing_under_stalls(dut):
    """Two words DC_STRIDE bytes apart share a cache index: stores and
    loads of both, alternating, under random dmem stalls must always see
    their own word, never the alias."""
    a, b = 0x100, 0x100 + DC_STRIDE
    program = [
        LUI (10, a >> 12), ADDI(10, 10, a & 0xFFF),    # 0, 4    x10 = a
        LUI (11, b >> 12), ADDI(11, 11, b & 0xFFF),    # 8, 12   x11 = b
        ADDI(1, 0, 5),           # 16  x1 = trip count
        LW  (2, 10, 0),          # 20  loop: a (fills a)
        LW  (12, 10, 0),         # 24  a again: hit
        LW  (3, 11, 0),          # 28  b: tag mismatch, evicts a
        LW  (4, 10, 0),          # 32  a: tag mismatch, evicts b
        ADD (5, 5, 2),           # 36
        ADD (6, 6, 3),           # 40
        ADD (7, 7, 4),           # 44
        ADD (13, 13, 12),        # 48
        ADDI(2, 2, 3),           # 52
        SW  (2, 10, 0),          # 56  a += 3
        ADDI(3, 3, 5),           # 60
        SW  (3, 11, 0),          # 64  b += 5 (evicts a)
        ADDI(1, 1, -1),          # 68
        BNE (1, 0, -52),         # 72  -> 20
        LW  (8, 10, 0),          # 76
        LW  (9, 11, 0),          # 80
        EBREAK(),                # 84
    ]
    init = {a: 1000, b: 2000}
    base, base_dmem = await _run(dut, program, dmem_init=init, max_cycles=400)
    assert _trace(base) == _golden(program, dmem_init=init)
    regs = _regs(base)
    assert (regs[8], regs[9]) == (1000 + 15, 2000 + 25), regs
    assert regs[5] == regs[7] == regs[13] == 5 * 1000 + 3 * (0 + 1 + 2 + 3 + 4)
    assert base_dmem == {a: 1015, b: 2025}, base_dmem
    served = 0
    for seed in range(4):
        log = []
        rets, dmem = await _run(dut, program, dmem_init=init, max_cycles=1500,
                                ready=_random_ready_p(4100 + seed, 0.22, 0.5),
                                start_clock=False, dmem_log=log)
        assert _arch_mem(rets) == _arch_mem(base), f"seed {seed}: RVFI stream differs"
        assert dmem == base_dmem, f"seed {seed}: {dmem}"
        served += len(_cache_served(rets, log))
    assert served, "no load was served from the cache"


def _mem_stress_program(rng, bases, body_len=48):
    """Random LW/LH/LHU/LB/LBU/SW/SH/SB/ADD/ADDI body (a few misaligned
    accesses included) over 8 words at each base, run twice by a loop
    so the second pass finds cached words."""
    prog = []
    for i, base in enumerate(bases):
        prog += [LUI(1 + i, base >> 12), ADDI(1 + i, 1 + i, base & 0xFFF)]
    prog += [ADDI(r, 0, rng.randrange(-2048, 2048)) for r in range(4, 12)]
    prog += [ADDI(31, 0, 2)]
    head = len(prog)
    loads = [(LW, 4), (LH, 2), (LHU, 2), (LB, 1), (LBU, 1)]
    stores = [(SW, 4), (SH, 2), (SB, 1)]
    for _ in range(body_len):
        k = rng.random()
        rb = rng.randrange(1, 1 + len(bases))
        rd, rs, rt = (rng.randrange(4, 12) for _ in range(3))
        if k < 0.6:
            op, n = rng.choice(loads if k < 0.35 else stores)
            off = 4 * rng.randrange(8) + n * rng.randrange(4 // n)
            if rng.random() < 0.05 and n > 1:
                off += 1                                   # misaligned: traps
            prog.append(op(rd, rb, off) if k < 0.35 else op(rs, rb, off))
        elif k < 0.8:
            prog.append(ADD(rd, rs, rt))
        else:
            prog.append(ADDI(rd, rs, rng.randrange(-2048, 2048)))
    prog += [ADDI(31, 31, -1)]
    prog += [BNE(31, 0, 4 * (head - len(prog))), EBREAK()]
    return prog


@cocotb.test()
async def random_mem_stress_under_stalls(dut):
    """Seeded random load/store/ALU programs over three bases one cache
    size apart (same indices, different tags). Each program's zero-wait
    run matches the golden ISS; runs under random imem + dmem stall
    profiles up to 0.6 must match it exactly (RVFI incl. memory data,
    final dmem, bus write order), and some loads must be cache-served."""
    bases = [0x300 + k * DC_STRIDE for k in range(3)]
    first, served = True, 0
    for seed in range(6):
        rng = random.Random(5000 + seed)
        prog = _mem_stress_program(rng, bases)
        init = {b + 4 * w: rng.getrandbits(32) for b in bases for w in range(8)}
        base, base_dmem = await _run(dut, prog, dmem_init=init, max_cycles=800,
                                     start_clock=first)
        first = False
        assert _trace(base) == _golden(prog, dmem_init=init), f"seed {seed}"
        profiles = [(0.22, 0.22), (0.0, 0.6), (0.4, 0.4), (0.6, 0.6)]
        for k, (pi, pd) in enumerate(profiles):
            log = []
            rets, dmem = await _run(dut, prog, dmem_init=init, max_cycles=4000,
                                    ready=_random_ready_p(100 * seed + k, pi, pd),
                                    start_clock=False, dmem_log=log)
            assert _arch_mem(rets) == _arch_mem(base), (
                f"seed {seed} profile {k}: RVFI stream differs under stalls")
            assert dmem == base_dmem, f"seed {seed} profile {k}: dmem differs"
            _check_bus_order(_accepted_dmem(log), _retired_dmem(rets))
            served += len(_cache_served(rets, log))
    assert served, "no load was served from the cache"


# ── Late branch: a BRANCH reading the LOAD right ahead of it ──────────────
# It skips the load-use stall, is resolved in MEM against the loaded data
# and, on a mispredict, redirects from WB one cycle later (late_kill): the
# instruction right behind it is then already in MEM and must be dropped
# (no dmem access, no divide result, no retirement).
LATE_BASE = 0x40
LATE_FAR  = 0xDEAD0000        # far outside dmem/imem (cosim flags any access)


def _late_cyc(rets, pc, k=0):
    return [r["cycle"] for r in rets if r["pc"] == pc][k]


def _no_far_access(dmem_log, fetch_log):
    """No bus access of either kind to the far address: a wrong-path
    load / store / JALR right behind a late branch never reaches a bus."""
    bad_d = [(c, da, ren, wen) for c, da, ren, wen, _ in dmem_log
             if (ren or wen) and (da & ~3) == LATE_FAR]
    bad_i = [(c, ia) for c, ia, _ in fetch_log if ia >= 0x1000]
    assert not bad_d, f"wrong-path dmem access: {bad_d}"
    assert not bad_i, f"wrong-path fetch: {bad_i}"


async def _bht_reset(dut, pcs, start_clock=False):
    """Put the BHT counters of the branches at `pcs` back to their
    power-on value (01, weakly not-taken). The BHT has no reset, so
    earlier runs leave trained counters behind: three not-taken passes
    saturate each counter at 00, then one taken pass (target pc+4)
    raises it to 01."""
    for taken in (False, False, False, True):
        prog = [NOP()] * (max(pcs) // 4 + 1) + [EBREAK()]
        for pc in pcs:
            prog[pc // 4] = BEQ(0, 0, 4) if taken else BNE(0, 0, 4)
        await _run(dut, prog, start_clock=start_clock, clear_regs=False)
        start_clock = False


# Countdown through memory with a late BEQ exit test: predicted not-taken
# and right LATE_ITERS times (no load-use bubble), then taken (late
# mispredict, 3 bubbles). A late BNE back edge covers the other
# directions: first sighting mispredicted taken, trained taken, then
# mispredicted not-taken. The late operand is rs1 in one, rs2 in the
# other, and the non-load operand of the BNE is forwarded from MEM/WB.
LATE_ITERS = 6
PROG_LATE_LOOP = [
    ADDI(1, 0, LATE_BASE),   # 0   x1 = base
    ADDI(2, 0, LATE_ITERS),  # 4
    SW  (2, 1, 0),           # 8   mem[base] = N
    ADDI(5, 0, 0),           # 12
    LW  (3, 1, 0),           # 16  loop: x3 = mem[base]
    BEQ (3, 0, 24),          # 20  late (rs1): x3 == 0 -> 44
    ADDI(3, 3, -1),          # 24  x3 via MEM/WB forward
    SW  (3, 1, 0),           # 28
    ADDI(5, 5, 1),           # 32
    JAL (0, -20),            # 36  -> 16
    ADDI(9, 0, 99),          # 40  never reached
    ADDI(6, 0, LATE_ITERS),  # 44  exit: second loop, x6 = trip count
    SW  (6, 1, 4),           # 48  mem[base+4] = N
    LW  (7, 1, 4),           # 52  loop2: x7 = mem[base+4]
    ADDI(7, 7, -1),          # 56
    SW  (7, 1, 4),           # 60
    ADDI(8, 0, 0),           # 64  x8 = 0 (MEM/WB-forwarded below)
    LW  (4, 1, 4),           # 68  x4 = mem[base+4]
    BNE (8, 4, -20),         # 72  late (rs2): x4 != 0 -> 52
    ADD (10, 5, 4),          # 76
    EBREAK(),                # 80
]
LATE_LOOP_PCS = ([0, 4, 8, 12] + [16, 20, 24, 28, 32, 36] * LATE_ITERS
                 + [16, 20, 44, 48] + [52, 56, 60, 64, 68, 72] * LATE_ITERS
                 + [76, 80])


@cocotb.test()
async def late_branch_loops(dut):
    """LW -> dependent BEQ / BNE: retired stream matches the golden ISS, a
    correctly predicted late branch costs no bubble, and a late
    mispredict (either direction) costs exactly three."""
    await _bht_reset(dut, [20, 72], start_clock=True)
    rets, dmem = await _run(dut, PROG_LATE_LOOP, max_cycles=400,
                            start_clock=False)
    _check_pred(rets, PROG_LATE_LOOP, LATE_LOOP_PCS,
                {5: LATE_ITERS, 10: LATE_ITERS})
    assert dmem == {LATE_BASE: 0, LATE_BASE + 4: 0}, dmem
    for k in range(LATE_ITERS):
        # LW, late BEQ and the instruction behind it retire back to back.
        lw, beq = _late_cyc(rets, 16, k), _late_cyc(rets, 20, k)
        assert (beq - lw, _late_cyc(rets, 24, k) - beq) == (1, 1), (k, lw, beq)
    for k in range(1, LATE_ITERS):
        # Steady state: one retirement per cycle around the whole loop.
        assert _late_cyc(rets, 16, k) - _late_cyc(rets, 16, k - 1) == 6
    # Taken BEQ, predicted not-taken: redirect from WB, 3 bubbles.
    assert _late_cyc(rets, 44) - _late_cyc(rets, 20, LATE_ITERS) == 4
    # BNE: taken but predicted not-taken the first time, then trained.
    bne = [r["cycle"] for r in rets if r["pc"] == 72]
    assert _late_cyc(rets, 52, 1) - bne[0] == 4
    assert _late_cyc(rets, 52, 2) - bne[1] == 1
    # Last BNE: not taken but predicted taken.
    assert _late_cyc(rets, 76) - bne[-1] == 4
    lw2 = _late_cyc(rets, 68, 3)
    assert _late_cyc(rets, 72, 3) - lw2 == 1


# All six conditions, each late against a loaded value, over signed /
# unsigned edge values, in both operand orders; the branch skips an
# ADDI so its outcome shows in x5 and in the retired stream.
LATE_VALS = [0, 1, -1, 7, -7, 0x7FFFFFFF, -0x80000000, 7, 3, -1]


def _late_cond_program(br, load_rs2):
    n = len(LATE_VALS)
    head = [
        ADDI(10, 0, LATE_BASE),
        ADDI(1, 0, n),
        ADDI(4, 0, 7),       # threshold
        ADDI(5, 0, 0),
    ]
    body = [
        LW  (3, 10, 0),                               # 16  loop: x3 = *x10
        br(4, 3, 8) if load_rs2 else br(3, 4, 8),     # 20  late -> skip
        ADDI(5, 5, 1),                                # 24  if not taken
        ADDI(10, 10, 4),                              # 28
        ADDI(1, 1, -1),                               # 32
        BNE (1, 0, -20),                              # 36  -> 16
        EBREAK(),                                     # 40
    ]
    init = {LATE_BASE + 4 * i: v & M32 for i, v in enumerate(LATE_VALS)}
    return head + body, init


@cocotb.test()
async def late_branch_all_conditions(dut):
    """BEQ/BNE/BLT/BGE/BLTU/BGEU as late branches (load in rs1 and in
    rs2): every retirement, incl. rs1/rs2_rdata = the loaded value,
    matches the golden ISS, zero-wait and under bus stalls."""
    first = True
    for br in (BEQ, BNE, BLT, BGE, BLTU, BGEU):
        for load_rs2 in (False, True):
            prog, init = _late_cond_program(br, load_rs2)
            base, _ = await _run(dut, prog, dmem_init=init, max_cycles=600,
                                 start_clock=first)
            first = False
            assert _trace(base) == _golden(prog, dmem_init=init), (br, load_rs2)
            _check_order(base)
            # The retirement right before each late branch is its LW.
            for lw, r in zip(base, base[1:]):
                if r["pc"] == 20:
                    assert lw["pc"] == 16, (br, load_rs2, lw)
                    val = lw["rd_wdata"]
                    want = (7, val) if load_rs2 else (val, 7)
                    assert (r["rs1_rdata"], r["rs2_rdata"]) == want, (br, r)
            rets, _ = await _run(dut, prog, dmem_init=init, max_cycles=2000,
                                 ready=_random_ready_p(7000, 0.2, 0.5),
                                 start_clock=False)
            assert _arch_mem(rets) == _arch_mem(base), (br, load_rs2)


# A late mispredict with a SW, and with a LW / SW to a far address, right
# behind it: the store never reaches dmem, and no access to the far
# address ever reaches the bus. Each BEQ is predicted not-taken (first
# sighting) and taken, so the fall-through is the wrong path.
PROG_LATE_STORE = [
    ADDI(1, 0, LATE_BASE),   # 0
    LUI (7, LATE_FAR >> 12), # 4   x7 = far address
    ADDI(9, 0, 0x55),        # 8
    LW  (3, 1, 0),           # 12  x3 = 0
    BEQ (3, 0, 12),          # 16  late, taken, predicted not-taken -> 28
    SW  (9, 1, 8),           # 20  wrong path: must not write
    ADDI(9, 0, 0x66),        # 24  wrong path
    LW  (3, 1, 0),           # 28  x3 = 0
    BEQ (3, 0, 12),          # 32  late, taken -> 44
    LW  (8, 7, 0),           # 36  wrong path: far load
    SW  (9, 7, 0),           # 40  wrong path: far store
    LW  (3, 1, 4),           # 44  x3 = 1
    BEQ (0, 3, 12),          # 48  late (rs2), not taken
    SW  (9, 1, 12),          # 52  right path: writes 0x55
    JAL (0, 8),              # 56  -> 64
    SW  (7, 7, 0),           # 60  never reached
    LW  (3, 1, 0),           # 64  x3 = 0
    BNE (3, 0, 8),           # 68  late, not taken
    EBREAK(),                # 72
]


@cocotb.test()
async def late_mispredict_drops_mem_op(dut):
    """The wrong-path SW / LW / far SW right behind a late mispredict
    never reach dmem; the bus sees exactly the retired accesses."""
    init = {LATE_BASE: 0, LATE_BASE + 4: 1}
    first = True
    for ready in (None, _random_ready_p(7100, 0.2, 0.4)):
        await _bht_reset(dut, [16, 32, 48, 68], start_clock=first)
        dlog, flog = [], []
        rets, dmem = await _run(dut, PROG_LATE_STORE, dmem_init=init,
                                max_cycles=600, ready=ready, start_clock=False,
                                dmem_log=dlog, fetch_log=flog)
        first = False
        assert _trace(rets) == _golden(PROG_LATE_STORE, dmem_init=init)
        _check_order(rets)
        assert not [r for r in rets if r["pc"] in (20, 24, 36, 40, 60)]
        assert dmem == {LATE_BASE: 0, LATE_BASE + 4: 1,
                        LATE_BASE + 12: 0x55}, dmem
        _no_far_access(dlog, flog)
        if ready is None:
            # Both taken BEQs really were late mispredicts (3 bubbles).
            assert _late_cyc(rets, 28) - _late_cyc(rets, 16) == 4
            assert _late_cyc(rets, 44) - _late_cyc(rets, 32) == 4
            assert _accepted_dmem(dlog) == _retired_dmem(rets)
        else:
            _check_bus_order(_accepted_dmem(dlog), _retired_dmem(rets))


# A late mispredict with a DIV right behind it (started in EX, then
# killed in its first busy cycle) and with a DIV two behind it (killed on
# its start cycle): neither may leave a result for the right-path DIVs.
PROG_LATE_DIV = [
    ADDI(1, 0, LATE_BASE),   # 0
    ADDI(11, 0, 100),        # 4
    ADDI(12, 0, 7),          # 8
    ADDI(13, 0, 3),          # 12
    LW  (3, 1, 0),           # 16  x3 = 0
    BEQ (3, 0, 12),          # 20  late, taken, predicted not-taken -> 32
    DIV (14, 11, 13),        # 24  wrong path, right behind: 100 / 3
    ADDI(9, 0, 99),          # 28  wrong path
    DIV (15, 11, 12),        # 32  right path: 100 / 7 = 14
    LW  (3, 1, 0),           # 36  x3 = 0
    BEQ (3, 0, 12),          # 40  late, taken -> 52
    ADDI(9, 0, 98),          # 44  wrong path
    DIV (14, 11, 13),        # 48  wrong path, two behind: 100 / 3
    DIV (16, 12, 13),        # 52  right path: 7 / 3 = 2
    ADD (17, 15, 16),        # 56
    EBREAK(),                # 60
]


@cocotb.test()
async def late_mispredict_kills_divide(dut):
    """A wrong-path DIV right behind or two behind a late mispredict is
    dropped with the divider: the right-path DIVs get their own results,
    and nothing from the wrong path retires."""
    init = {LATE_BASE: 0}
    first = True
    for ready in (None, _random_ready_p(7200, 0.2, 0.3)):
        await _bht_reset(dut, [20, 40], start_clock=first)
        rets, _ = await _run(dut, PROG_LATE_DIV, dmem_init=init,
                             max_cycles=800, ready=ready, start_clock=False)
        first = False
        assert _trace(rets) == _golden(PROG_LATE_DIV, dmem_init=init)
        _check_order(rets)
        assert not [r for r in rets if r["pc"] in (24, 28, 44, 48)]
        _expect(_one(rets, DIV(15, 11, 12)), 15, 14, 100, 7)
        _expect(_one(rets, DIV(16, 12, 13)), 16, 2, 7, 3)
        _expect(_one(rets, ADD(17, 15, 16)), 17, 16)


# A late branch whose taken target is misaligned: it traps and falls
# through (IF never predicts it, so it is no mispredict); not taken, it
# does not trap.
PROG_LATE_MISALIGN = [
    ADDI(1, 0, LATE_BASE),   # 0
    ADDI(2, 0, 3),           # 4   trip count
    LW  (3, 1, 0),           # 8   loop: x3 = mem[base] (= 5, then 0)
    BNE (3, 0, 6),           # 12  late: taken -> 18 misaligned: trap
    SW  (0, 1, 0),           # 16  mem[base] = 0
    ADDI(2, 2, -1),          # 20
    BNE (2, 0, -16),         # 24  -> 8
    ADDI(4, 0, 7),           # 28
    EBREAK(),                # 32
]


@cocotb.test()
async def late_branch_misaligned_target(dut):
    """A taken late BNE to a misaligned target traps, writes nothing and
    falls through (pc_wdata = pc+4); not taken it retires normally."""
    init = {LATE_BASE: 5}
    first = True
    for ready in (None, _random_ready_p(7300, 0.2, 0.4)):
        log = []
        rets, _ = await _run(dut, PROG_LATE_MISALIGN, dmem_init=init,
                             max_cycles=400, ready=ready, start_clock=first,
                             fetch_log=log)
        first = False
        assert _trace(rets) == _golden(PROG_LATE_MISALIGN, dmem_init=init)
        late = [r for r in rets if r["pc"] == 12]
        assert [(r["trap"], r["pc_next"]) for r in late] == \
               [(1, 16), (0, 16), (0, 16)], late
        assert not [ia for _, ia, _ in log if ia & 3], "misaligned fetch"


# The LOAD ahead of a late branch traps (misaligned): it writes nothing,
# so the branch must see the register's old value. The late path replays
# the branch (it does not retire from there) and it then resolves
# normally. x3 = 5 before the trapping loads; x3 == x5 is taken.
PROG_LATE_LDTRAP = [
    ADDI(1, 0, LATE_BASE),   # 0
    ADDI(3, 0, 5),           # 4
    ADDI(5, 0, 5),           # 8
    LW  (3, 1, 1),           # 12  misaligned: traps, x3 stays 5
    BEQ (3, 5, 8),           # 16  x3 (old) == 5: taken -> 24
    ADDI(9, 0, 99),          # 20  skipped
    LH  (3, 1, 3),           # 24  misaligned: traps
    BNE (5, 3, 8),           # 28  late (rs2), 5 != 5: not taken
    ADDI(6, 0, 1),           # 32
    LW  (3, 1, 0),           # 36  aligned: x3 = mem[base]
    BEQ (3, 5, 8),           # 40  late, mem[base] = 9 != 5: not taken
    ADDI(7, 0, 1),           # 44
    EBREAK(),                # 48
]


@cocotb.test()
async def late_branch_after_trapping_load(dut):
    """A late branch behind a misaligned (trapping) LW / LH compares the
    register's old value, retires exactly once, and reports it as
    rs1/rs2_rdata."""
    init = {LATE_BASE: 9}
    first = True
    for ready in (None, _random_ready_p(7400, 0.2, 0.4)):
        rets, _ = await _run(dut, PROG_LATE_LDTRAP, dmem_init=init,
                             max_cycles=400, ready=ready, start_clock=first)
        first = False
        assert _trace(rets) == _golden(PROG_LATE_LDTRAP, dmem_init=init)
        _check_order(rets)
        assert [r["trap"] for r in rets if r["pc"] in (12, 24)] == [1, 1]
        beq = _one(rets, BEQ(3, 5, 8), pc=16)
        assert (beq["rs1_rdata"], beq["rs2_rdata"]) == (5, 5)
        bne = _one(rets, BNE(5, 3, 8), pc=28)
        assert (bne["rs1_rdata"], bne["rs2_rdata"]) == (5, 5)
        _one(rets, BEQ(3, 5, 8), pc=40)


# A JALR right behind a late branch: if the branch mispredicts, the JALR
# is wrong-path and its rs1 may be anything (here a far address). It
# must never redirect fetch there; on the right path it still works.
PROG_LATE_JALR = [
    ADDI(1, 0, LATE_BASE),   # 0
    LUI (7, LATE_FAR >> 12), # 4   x7 = far address
    ADDI(8, 0, 36),          # 8   x8 = 36
    LW  (3, 1, 0),           # 12  x3 = 0
    BEQ (3, 0, 12),          # 16  late, taken, predicted not-taken -> 28
    JALR(0, 7, 0),           # 20  wrong path: jump to the far address
    ADDI(9, 0, 99),          # 24  wrong path
    LW  (3, 1, 4),           # 28  x3 = 1
    BEQ (3, 0, 12),          # 32  late, not taken
    JALR(6, 8, 12),          # 36  right path: -> 48, x6 = 40
    ADDI(9, 0, 98),          # 40  skipped
    ADDI(9, 0, 97),          # 44  skipped
    ADD (10, 6, 3),          # 48  x10 = 41
    EBREAK(),                # 52
]


@cocotb.test()
async def late_mispredict_wrong_path_jalr(dut):
    """A wrong-path JALR right behind a late mispredict never fetches from
    its (far) target; a right-path one right behind a late branch works
    (after a one-cycle stall)."""
    init = {LATE_BASE: 0, LATE_BASE + 4: 1}
    first = True
    for ready in (None, _random_ready_p(7500, 0.2, 0.4)):
        await _bht_reset(dut, [16, 32], start_clock=first)
        dlog, flog = [], []
        rets, _ = await _run(dut, PROG_LATE_JALR, dmem_init=init,
                             max_cycles=400, ready=ready, start_clock=False,
                             dmem_log=dlog, fetch_log=flog)
        first = False
        assert _trace(rets) == _golden(PROG_LATE_JALR, dmem_init=init)
        _no_far_access(dlog, flog)
        _expect(_one(rets, ADD(10, 6, 3)), 10, 41)
        if ready is None:
            # The first BEQ was a late mispredict with the JALR behind it.
            assert _late_cyc(rets, 28) - _late_cyc(rets, 16) == 4
            assert _late_cyc(rets, 36) - _late_cyc(rets, 32) == 2


# Random load -> branch programs, run under bus backpressure. Each block
# is a load, a branch that usually reads it (late), and a few
# instructions the branch may skip: stores, loads (some misaligned, so
# the late-branch replay runs), ALU ops and divides. An outer loop runs
# the body twice so the BHT trains and predicted-taken mispredicts occur.
def _late_stress_program(rng, blocks=14):
    base = LATE_BASE
    prog = [ADDI(1, 0, base)]
    prog += [ADDI(r, 0, rng.choice([0, 1, -1, 5, 7, -7, 100])) for r in range(4, 12)]
    prog += [ADDI(31, 0, 2)]
    head = len(prog)
    conds = (BEQ, BNE, BLT, BGE, BLTU, BGEU)
    regs = list(range(4, 12))
    for _ in range(blocks):
        rd = rng.choice(regs)
        off = 4 * rng.randrange(8)
        if rng.random() < 0.08:
            prog.append(LW(rd, 1, off + 2))                       # traps
        else:
            prog.append(rng.choice([LW, LH, LBU, LB])(rd, 1, off))
        other = rng.choice(regs + [0])
        a, b = (rd, other) if rng.random() < 0.5 else (other, rd)
        if rng.random() < 0.15:
            a = rng.choice(regs)                                  # maybe not late
        skip = rng.randrange(1, 4)
        prog.append(rng.choice(conds)(a, b, 4 * (skip + 1)))
        for _ in range(skip):
            k = rng.random()
            r1, r2, r3 = (rng.choice(regs) for _ in range(3))
            if k < 0.25:
                prog.append(SW(r1, 1, 4 * rng.randrange(8)))
            elif k < 0.4:
                prog.append(LW(r1, 1, 4 * rng.randrange(8)))
            elif k < 0.5:
                prog.append(DIV(r1, r2, r3))
            elif k < 0.75:
                prog.append(ADD(r1, r2, r3))
            else:
                prog.append(ADDI(r1, r2, rng.randrange(-64, 64)))
    prog.append(ADDI(31, 31, -1))
    prog.append(BNE(31, 0, 4 * (head - len(prog))))
    prog.append(EBREAK())
    init = {base + 4 * w: rng.choice([0, 1, 5, 7, M32, 0x80000000,
                                      rng.getrandbits(32)])
            for w in range(8)}
    return prog, init


@cocotb.test()
async def late_branch_random_under_stalls(dut):
    """Random load -> branch programs: the zero-wait run matches the
    golden ISS, and runs under random imem / dmem stall profiles match
    it exactly (RVFI incl. memory data, final dmem, bus write order)."""
    first = True
    for seed in range(8):
        rng = random.Random(7600 + seed)
        prog, init = _late_stress_program(rng)
        base, base_dmem = await _run(dut, prog, dmem_init=init,
                                     max_cycles=3000, start_clock=first)
        first = False
        assert _trace(base) == _golden(prog, dmem_init=init), f"seed {seed}"
        _check_order(base)
        for k, (pi, pd) in enumerate([(0.0, 0.5), (0.22, 0.22), (0.5, 0.7)]):
            log = []
            rets, dmem = await _run(dut, prog, dmem_init=init,
                                    max_cycles=12000,
                                    ready=_random_ready_p(50 * seed + k, pi, pd),
                                    start_clock=False, dmem_log=log)
            assert _arch_mem(rets) == _arch_mem(base), f"seed {seed} profile {k}"
            assert dmem == base_dmem, f"seed {seed} profile {k}"
            _check_bus_order(_accepted_dmem(log), _retired_dmem(rets))


def test_pipeline_runner():
    run_cocotb(
        toplevel="core",
        sources=[
            "core_pkg.sv",
            "alu.sv", "div_unit.sv", "decoder.sv", "imm_gen.sv", "reg_file.sv",
            "if_stage.sv", "id_stage.sv", "ex_stage.sv",
            "mem_stage.sv", "wb_stage.sv",
            "hazard_unit.sv", "forward_unit.sv",
            "core.sv",
        ],
        test_module="test_pipeline",
    )
