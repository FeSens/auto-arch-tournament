"""Unit tests for rtl/imm_gen.sv."""
from __future__ import annotations

import cocotb
from cocotb.triggers import Timer

from _helpers import run_cocotb


async def _check(dut, instr, expected):
    dut.instr.value = instr & 0xFFFFFFFF
    await Timer(1, "ns")
    actual = int(dut.imm.value) & 0xFFFFFFFF
    assert actual == (expected & 0xFFFFFFFF), (
        f"instr=0x{instr:08x}: expected imm=0x{expected & 0xFFFFFFFF:08x} "
        f"got 0x{actual:08x}"
    )


@cocotb.test()
async def i_type_load(dut):
    # LW x0, 4(x0)  = 0x00402003 -> imm = 4
    await _check(dut, 0x00402003, 0x00000004)
    # LW x0, -1(x0) = 0xFFF02003 -> imm = -1 = 0xFFFFFFFF
    await _check(dut, 0xFFF02003, 0xFFFFFFFF)


@cocotb.test()
async def i_type_op_imm(dut):
    # ADDI x0, x0, 5    -> 0x00500013
    await _check(dut, 0x00500013, 0x00000005)
    # ADDI x0, x0, -2048-> 0x80000013 -> imm = 0xFFFFF800
    await _check(dut, 0x80000013, 0xFFFFF800)
    # ADDI x0, x0, 2047 -> 0x7FF00013 -> imm = 0x000007FF
    await _check(dut, 0x7FF00013, 0x000007FF)


@cocotb.test()
async def i_type_jalr(dut):
    # JALR x1, 8(x1) = 0x008080E7 -> imm = 8
    await _check(dut, 0x008080E7, 0x00000008)


@cocotb.test()
async def s_type(dut):
    # SW x1, 4(x2)  = 0x00112223 -> imm = 4
    await _check(dut, 0x00112223, 0x00000004)
    # SW x1, -1(x2) — encoded with imm[11:5]=0x7F (funct7), imm[4:0]=0x1F (rd)
    # = 0xFE112FA3 -> imm = -1 = 0xFFFFFFFF
    await _check(dut, 0xFE112FA3, 0xFFFFFFFF)


@cocotb.test()
async def b_type(dut):
    # BEQ x0, x0, +4 = 0x00000263 -> imm = 4
    await _check(dut, 0x00000263, 0x00000004)
    # BEQ x0, x0, +8 = 0x00000463 -> imm = 8
    await _check(dut, 0x00000463, 0x00000008)


@cocotb.test()
async def u_type_lui(dut):
    # LUI x1, 0x12345 -> 0x123450B7  -> imm = 0x12345000
    await _check(dut, 0x123450B7, 0x12345000)
    # LUI x1, 0xFFFFF -> 0xFFFFF0B7  -> imm = 0xFFFFF000
    await _check(dut, 0xFFFFF0B7, 0xFFFFF000)


@cocotb.test()
async def u_type_auipc(dut):
    # AUIPC x1, 0x12345 -> 0x12345097 -> imm = 0x12345000
    await _check(dut, 0x12345097, 0x12345000)


@cocotb.test()
async def j_type(dut):
    # JAL x0, +8 = 0x0080006F -> imm = 8
    await _check(dut, 0x0080006F, 0x00000008)
    # JAL x0, -4 = 0xFFDFF06F -> imm = -4 = 0xFFFFFFFC
    await _check(dut, 0xFFDFF06F, 0xFFFFFFFC)


def test_imm_gen_runner():
    run_cocotb(toplevel="imm_gen",
               sources=["imm_gen.sv"],
               test_module="test_imm_gen")
