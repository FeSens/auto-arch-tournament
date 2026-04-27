"""End-to-end pipeline tests for rtl/core.sv.

Drives a minimal Python-side imem/dmem against the core's combinational
fetch/load model and captures RVFI retirements. Covers the §8 phase-2
acceptance set: forwarding (EX->EX, MEM->EX), branches, JAL, JALR,
SW+LW roundtrip, load-use stall, and the trap discipline (illegal /
ECALL trap, EBREAK does NOT trap).
"""
from __future__ import annotations

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
def ADD (rd, rs1, rs2): return _r(0, rs2, rs1, 0b000, rd, 0b0110011)
def LW  (rd, rs1, imm): return _i(imm & 0xFFF, rs1, 0b010, rd, 0b0000011)
def SW  (rs2, rs1, imm): return _s(imm & 0xFFF, rs2, rs1, 0b010, 0b0100011)
def BEQ (rs1, rs2, imm): return _b(imm, rs2, rs1, 0b000, 0b1100011)
def JAL (rd, imm):       return _j(imm, rd, 0b1101111)
def JALR(rd, rs1, imm):  return _i(imm & 0xFFF, rs1, 0b000, rd, 0b1100111)
def NOP():               return ADDI(0, 0, 0)        # = 0x00000013
def EBREAK():            return 0x00100073
def ECALL():             return 0x00000073


# ── Harness ────────────────────────────────────────────────────────────────
async def _run(dut, program, dmem_init=None, max_cycles=200):
    """Drive imem/dmem; capture RVFI retirements until EBREAK or max_cycles.

    imem is read combinationally each cycle from imemAddr; dmem similarly.
    Stores get applied to the Python-side dmem dict so subsequent loads
    see the new value.

    Returns (retirements, dmem) where retirements is a list of dicts
    sampled on every cycle that rvfi_valid=1.
    """
    imem = {i * 4: instr & 0xFFFFFFFF for i, instr in enumerate(program)}
    dmem = dict(dmem_init or {})
    retirements: list[dict] = []

    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())

    dut.reset.value = 1
    dut.io_imemData.value = 0
    dut.io_dmemRData.value = 0
    for _ in range(3):
        await RisingEdge(dut.clock)

    # Deassert reset and prime the imem read for the first PC=0 fetch.
    dut.reset.value = 0
    dut.io_imemData.value = imem.get(0, EBREAK())

    for cycle in range(max_cycles):
        await RisingEdge(dut.clock)
        await Timer(1, "ns")  # let combinational signals settle

        # Sample the post-edge state.
        ia        = int(dut.io_imemAddr.value)
        da        = int(dut.io_dmemAddr.value)
        wen       = int(dut.io_dmemWEn.value)
        rvfi_v    = int(dut.io_rvfi_valid.value)

        # Apply dmem write side effects.
        if wen:
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
                "order":     int(dut.io_rvfi_order.value),
                "insn":      int(dut.io_rvfi_insn.value),
                "pc":        int(dut.io_rvfi_pc_rdata.value),
                "pc_next":   int(dut.io_rvfi_pc_wdata.value),
                "rd":        int(dut.io_rvfi_rd_addr.value),
                "rd_wdata":  int(dut.io_rvfi_rd_wdata.value),
                "rs1_addr":  int(dut.io_rvfi_rs1_addr.value),
                "rs1_rdata": int(dut.io_rvfi_rs1_rdata.value),
                "rs2_addr":  int(dut.io_rvfi_rs2_addr.value),
                "rs2_rdata": int(dut.io_rvfi_rs2_rdata.value),
                "trap":      int(dut.io_rvfi_trap.value),
                "mem_addr":  int(dut.io_rvfi_mem_addr.value),
                "mem_wmask": int(dut.io_rvfi_mem_wmask.value),
                "mem_wdata": int(dut.io_rvfi_mem_wdata.value),
                "mem_rmask": int(dut.io_rvfi_mem_rmask.value),
                "mem_rdata": int(dut.io_rvfi_mem_rdata.value),
                "cycle":     cycle,
            }
            retirements.append(r)
            if r["insn"] == EBREAK():
                break

        # Drive next cycle's imem fetch and dmem read combinationally.
        dut.io_imemData.value  = imem.get(ia & ~3, EBREAK())
        dut.io_dmemRData.value = dmem.get(da & ~3, 0)
    else:
        raise AssertionError(f"max_cycles={max_cycles} reached without EBREAK")

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
    """BEQ x0, x0, +8 — the next instruction must NOT retire."""
    program = [
        BEQ(0, 0, 8),          # taken; skip next
        ADDI(1, 0, 99),        # SHOULD NOT retire as a real ADDI x1
        ADDI(2, 0, 42),        # branch target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    # No retirement should write x1=99.
    skipped = [r for r in rets if r["rd"] == 1 and r["rd_wdata"] == 99]
    assert not skipped, f"skipped instr leaked: {skipped}"
    [r2] = _by_insn(rets, ADDI(2, 0, 42))
    assert r2["rd_wdata"] == 42


@cocotb.test()
async def jal_writes_pc_plus_4(dut):
    """JAL x1, +8; verify x1 == PC_of_JAL + 4 and the next instr is the target."""
    program = [
        JAL(1, 8),             # PC=0; x1 := 4; jump to PC=8
        ADDI(2, 0, 99),        # PC=4 — skipped
        ADDI(3, 0, 42),        # PC=8 — target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    [rj] = _by_insn(rets, JAL(1, 8))
    assert rj["rd"] == 1
    assert rj["rd_wdata"] == rj["pc"] + 4, (
        f"JAL rd_wdata expected pc+4=0x{rj['pc']+4:x}, got 0x{rj['rd_wdata']:x}"
    )
    [r3] = _by_insn(rets, ADDI(3, 0, 42))
    assert r3["rd_wdata"] == 42


@cocotb.test()
async def jalr_target(dut):
    """ADDI x5, x0, 12; JALR x1, x5, 0 — jump to address in x5 = 12."""
    program = [
        ADDI(5, 0, 12),        # PC=0;  x5 := 12
        JALR(1, 5, 0),         # PC=4;  jump to x5+0 = 12
        ADDI(6, 0, 99),        # PC=8;  skipped
        ADDI(7, 0, 42),        # PC=12; target
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    [r7] = _by_insn(rets, ADDI(7, 0, 42))
    assert r7["rd_wdata"] == 42
    skipped = [r for r in rets if r["rd"] == 6 and r["rd_wdata"] == 99]
    assert not skipped


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
    """0xFFFFFFFF retires with rvfi_trap=1 and no rd write."""
    program = [
        0xFFFFFFFF,
        EBREAK(),
    ]
    rets, _ = await _run(dut, program)
    bad = next(r for r in rets if r["insn"] == 0xFFFFFFFF)
    assert bad["trap"] == 1
    assert bad["rd"] == 0       # decoder forces reg_write=0 on illegal
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


def test_pipeline_runner():
    run_cocotb(
        toplevel="core",
        sources=[
            "core_pkg.sv",
            "alu.sv", "decoder.sv", "imm_gen.sv", "reg_file.sv",
            "if_stage.sv", "id_stage.sv", "ex_stage.sv",
            "mem_stage.sv", "wb_stage.sv",
            "hazard_unit.sv", "forward_unit.sv",
            "core.sv",
        ],
        test_module="test_pipeline",
    )
