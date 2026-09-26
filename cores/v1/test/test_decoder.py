"""Unit tests for rtl/decoder.sv. Mirrors chisel/test/src/DecoderSpec.scala
1:1. Includes every reserved-encoding case from CLAUDE.md invariant #10."""
from __future__ import annotations

import cocotb
from cocotb.triggers import Timer

from _helpers import (
    ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR,
    ALU_SLT, ALU_SLTU, ALU_SLL, ALU_SRL, ALU_SRA,
    ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU,
    run_cocotb,
)


async def _poke(dut, instr):
    dut.instr.value = instr & 0xFFFFFFFF
    await Timer(1, "ns")


# ── R-type ────────────────────────────────────────────────────────────────
@cocotb.test()
async def add(dut):
    # ADD x1,x2,x3 = 0x003100B3
    await _poke(dut, 0x003100B3)
    assert int(dut.alu_op.value) == ALU_ADD
    assert int(dut.reg_write.value) == 1
    assert int(dut.alu_src.value) == 0
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def sub(dut):
    await _poke(dut, 0x403100B3)
    assert int(dut.alu_op.value) == ALU_SUB
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def r_type_ops(dut):
    cases = [
        (0x001010B3, ALU_SLL),
        (0x001020B3, ALU_SLT),
        (0x001030B3, ALU_SLTU),
        (0x001040B3, ALU_XOR),
        (0x001050B3, ALU_SRL),
        (0x001060B3, ALU_OR),
        (0x001070B3, ALU_AND),
        (0x401050B3, ALU_SRA),
    ]
    for instr, op in cases:
        await _poke(dut, instr)
        assert int(dut.alu_op.value) == op, \
            f"instr=0x{instr:08x}: expected aluOp={op}, got {int(dut.alu_op.value)}"
        assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def m_extension(dut):
    cases = [
        (0x023100B3, ALU_MUL),
        (0x023110B3, ALU_MULH),
        (0x023120B3, ALU_MULHSU),
        (0x023130B3, ALU_MULHU),
        (0x023140B3, ALU_DIV),
        (0x023150B3, ALU_DIVU),
        (0x023160B3, ALU_REM),
        (0x023170B3, ALU_REMU),
    ]
    for instr, op in cases:
        await _poke(dut, instr)
        assert int(dut.alu_op.value) == op
        assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def reserved_funct7_r_type(dut):
    # funct7=0x3F is reserved; otherwise valid R-type encoding.
    await _poke(dut, 0xFE3100B3)
    assert int(dut.is_illegal.value) == 1


@cocotb.test()
async def reserved_subsra_funct3(dut):
    # funct7=0x20, funct3=1 is reserved (only funct3=0 SUB or 5 SRA valid).
    await _poke(dut, 0x403110B3)
    assert int(dut.is_illegal.value) == 1


# ── I-type OP-IMM ─────────────────────────────────────────────────────────
@cocotb.test()
async def addi(dut):
    # ADDI x1, x0, 5 = 0x00500093
    await _poke(dut, 0x00500093)
    assert int(dut.alu_op.value) == ALU_ADD
    assert int(dut.alu_src.value) == 1
    assert int(dut.reg_write.value) == 1
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def slli_legal(dut):
    # SLLI x1, x0, 4 = 0x00401093
    await _poke(dut, 0x00401093)
    assert int(dut.alu_op.value) == ALU_SLL
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def slli_with_funct7_illegal(dut):
    # SLLI with funct7=0x20 is reserved.
    await _poke(dut, 0x40401093)
    assert int(dut.is_illegal.value) == 1


@cocotb.test()
async def srli(dut):
    await _poke(dut, 0x00405093)
    assert int(dut.alu_op.value) == ALU_SRL
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def srai(dut):
    await _poke(dut, 0x40405093)
    assert int(dut.alu_op.value) == ALU_SRA
    assert int(dut.is_illegal.value) == 0


# ── LOAD ──────────────────────────────────────────────────────────────────
@cocotb.test()
async def loads(dut):
    cases = [
        (0x00010083, 0, 1),  # LB    width=byte sext=1
        (0x00011083, 1, 1),  # LH
        (0x00012083, 2, 1),  # LW
        (0x00014083, 0, 0),  # LBU   sext=0
        (0x00015083, 1, 0),  # LHU
    ]
    for instr, mw, sext in cases:
        await _poke(dut, instr)
        assert int(dut.mem_read.value)   == 1
        assert int(dut.reg_write.value)  == 1
        assert int(dut.mem_to_reg.value) == 1
        assert int(dut.alu_src.value)    == 1
        assert int(dut.mem_width.value)  == mw, f"instr=0x{instr:08x} mw={mw} got {int(dut.mem_width.value)}"
        assert int(dut.mem_sext.value)   == sext
        assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def reserved_load_funct3(dut):
    for f3 in (3, 6, 7):
        instr = (f3 << 12) | 0x03
        await _poke(dut, instr)
        assert int(dut.is_illegal.value) == 1, f"LOAD funct3={f3} should be illegal"


# ── STORE ─────────────────────────────────────────────────────────────────
@cocotb.test()
async def stores(dut):
    cases = [(0x00110023, 0), (0x00111023, 1), (0x00112023, 2)]
    for instr, mw in cases:
        await _poke(dut, instr)
        assert int(dut.mem_write.value) == 1
        assert int(dut.reg_write.value) == 0
        assert int(dut.mem_width.value) == mw
        assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def reserved_store_funct3(dut):
    for f3 in range(3, 8):
        instr = (f3 << 12) | 0x23
        await _poke(dut, instr)
        assert int(dut.is_illegal.value) == 1, f"STORE funct3={f3} should be illegal"


# ── BRANCH ────────────────────────────────────────────────────────────────
@cocotb.test()
async def branches(dut):
    cases = [
        (0x00208463, BR_BEQ),
        (0x00209463, BR_BNE),
        (0x0020C463, BR_BLT),
        (0x0020D463, BR_BGE),
        (0x0020E463, BR_BLTU),
        (0x0020F463, BR_BGEU),
    ]
    for instr, op in cases:
        await _poke(dut, instr)
        assert int(dut.is_branch.value) == 1
        assert int(dut.reg_write.value) == 0
        assert int(dut.branch_op.value) == op
        assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def reserved_branch_funct3(dut):
    for f3 in (2, 3):
        instr = (f3 << 12) | 0x63
        await _poke(dut, instr)
        assert int(dut.is_illegal.value) == 1, f"BRANCH funct3={f3} should be illegal"


# ── JAL / JALR / LUI / AUIPC ──────────────────────────────────────────────
@cocotb.test()
async def jal(dut):
    # JAL x0, +4 = 0x0040006F
    await _poke(dut, 0x0040006F)
    assert int(dut.is_jump.value)    == 1
    assert int(dut.reg_write.value)  == 1
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def jalr(dut):
    # JALR x1, 0(x2) = 0x000100E7
    await _poke(dut, 0x000100E7)
    assert int(dut.is_jump.value)    == 1
    assert int(dut.is_jalr.value)    == 1
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def jalr_nonzero_funct3_illegal(dut):
    # JALR with any funct3 != 0 is reserved per spec.
    for f3 in range(1, 8):
        instr = (f3 << 12) | 0x000000E7  # rd=1 rs1=0 imm=0 funct3=f3 opcode=JALR
        await _poke(dut, instr)
        assert int(dut.is_illegal.value) == 1, (
            f"JALR funct3={f3} should be illegal (instr=0x{instr:08x})"
        )


@cocotb.test()
async def r_type_funct7_funct3_grid(dut):
    # Exhaustive sweep over the small (funct7, funct3) space for opcode 0x33.
    # Valid combos: funct7=0x00 any funct3; funct7=0x20 with funct3 ∈ {0,5};
    # funct7=0x01 (M-ext) any funct3. Everything else is reserved.
    for f7 in (0x00, 0x01, 0x20, 0x3F, 0x40, 0x7F):
        for f3 in range(8):
            instr = (f7 << 25) | (1 << 20) | (2 << 15) | (f3 << 12) | (1 << 7) | 0x33
            valid = (f7 == 0x00) or (f7 == 0x20 and f3 in (0, 5)) or (f7 == 0x01)
            await _poke(dut, instr)
            got = int(dut.is_illegal.value)
            expected = 0 if valid else 1
            assert got == expected, (
                f"R-type funct7=0x{f7:02x} funct3={f3} expected illegal={expected}, got {got}"
            )


@cocotb.test()
async def slli_srli_srai_funct7_sweep(dut):
    # OP-IMM shifts: SLLI must have funct7=0; SRLI/SRAI must have funct7
    # in {0x00, 0x20}. Anything else reserved.
    for f3, allowed_f7s in [(1, {0x00}), (5, {0x00, 0x20})]:
        for f7 in (0x00, 0x01, 0x20, 0x3F, 0x40, 0x7F):
            instr = (f7 << 25) | (1 << 20) | (0 << 15) | (f3 << 12) | (1 << 7) | 0x13
            await _poke(dut, instr)
            got = int(dut.is_illegal.value)
            expected = 0 if f7 in allowed_f7s else 1
            assert got == expected, (
                f"OP-IMM shift funct3={f3} funct7=0x{f7:02x} expected illegal={expected}, got {got}"
            )


@cocotb.test()
async def lui(dut):
    await _poke(dut, 0x12345037)
    assert int(dut.is_lui.value)     == 1
    assert int(dut.reg_write.value)  == 1
    assert int(dut.is_illegal.value) == 0


@cocotb.test()
async def auipc(dut):
    await _poke(dut, 0x12345017)
    assert int(dut.is_auipc.value)   == 1
    assert int(dut.reg_write.value)  == 1
    assert int(dut.is_illegal.value) == 0


# ── FENCE / SYSTEM ────────────────────────────────────────────────────────
@cocotb.test()
async def fence(dut):
    # FENCE iorw,iorw = 0x0FF0000F
    await _poke(dut, 0x0FF0000F)
    assert int(dut.is_illegal.value) == 0
    assert int(dut.reg_write.value)  == 0
    assert int(dut.mem_read.value)   == 0
    assert int(dut.mem_write.value)  == 0


@cocotb.test()
async def ebreak(dut):
    await _poke(dut, 0x00100073)
    assert int(dut.is_illegal.value) == 0
    assert int(dut.reg_write.value)  == 0


@cocotb.test()
async def ecall_is_illegal(dut):
    await _poke(dut, 0x00000073)
    assert int(dut.is_illegal.value) == 1


@cocotb.test()
async def csrrw_is_illegal(dut):
    # CSRRW x1, mstatus, x0 = 0x30001073
    await _poke(dut, 0x30001073)
    assert int(dut.is_illegal.value) == 1


@cocotb.test()
async def mret_is_illegal(dut):
    await _poke(dut, 0x30200073)
    assert int(dut.is_illegal.value) == 1


# ── Unknown opcodes ───────────────────────────────────────────────────────
@cocotb.test()
async def unknown_opcodes(dut):
    for instr in (0x0000007F, 0x0000002F, 0xFFFFFFFF, 0x00000000):
        await _poke(dut, instr)
        assert int(dut.is_illegal.value) == 1, \
            f"instr 0x{instr:08x} should be illegal"


def test_decoder_runner():
    run_cocotb(toplevel="decoder",
               sources=["core_pkg.sv", "decoder.sv"],
               test_module="test_decoder")
