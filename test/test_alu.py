"""Unit tests for rtl/alu.sv. Mirrors chisel/test/src/ALUSpec.scala 1:1."""
from __future__ import annotations

import cocotb
from cocotb.triggers import Timer

from _helpers import (
    ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR,
    ALU_SLT, ALU_SLTU, ALU_SLL, ALU_SRL, ALU_SRA,
    ALU_LUI,
    ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    run_cocotb,
)

MASK32 = 0xFFFFFFFF


async def _check(dut, op, a, b, expected):
    dut.op.value = op
    dut.a.value  = a & MASK32
    dut.b.value  = b & MASK32
    await Timer(1, "ns")
    actual = int(dut.out.value) & MASK32
    assert actual == (expected & MASK32), (
        f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
    )


@cocotb.test()
async def add(dut):
    await _check(dut, ALU_ADD, 5, 3, 8)
    await _check(dut, ALU_ADD, 0xFFFFFFFF, 1, 0)  # wrap


@cocotb.test()
async def sub(dut):
    await _check(dut, ALU_SUB, 10, 3, 7)
    await _check(dut, ALU_SUB, 0, 1, 0xFFFFFFFF)  # borrow


@cocotb.test()
async def bitwise(dut):
    await _check(dut, ALU_AND, 0xFF, 0x0F, 0x0F)
    await _check(dut, ALU_OR,  0xF0, 0x0F, 0xFF)
    await _check(dut, ALU_XOR, 0xFF, 0x0F, 0xF0)


@cocotb.test()
async def slt_signed(dut):
    await _check(dut, ALU_SLT, 0xFFFFFFFF, 0, 1)              # -1 < 0
    await _check(dut, ALU_SLT, 1, 0, 0)
    await _check(dut, ALU_SLT, 0x7FFFFFFF, 0x80000000, 0)     # MAX > MIN


@cocotb.test()
async def sltu_unsigned(dut):
    await _check(dut, ALU_SLTU, 0xFFFFFFFF, 0, 0)             # max > 0
    await _check(dut, ALU_SLTU, 0, 1, 1)


@cocotb.test()
async def sll(dut):
    await _check(dut, ALU_SLL, 1, 4, 16)
    await _check(dut, ALU_SLL, 1, 31, 0x80000000)
    await _check(dut, ALU_SLL, 1, 0x20, 1)                    # shamt = b[4:0] = 0


@cocotb.test()
async def srl(dut):
    await _check(dut, ALU_SRL, 0x80000000, 1, 0x40000000)
    await _check(dut, ALU_SRL, 0x80000000, 31, 1)
    await _check(dut, ALU_SRL, 0xFFFFFFFF, 0x25, 0x07FFFFFF)   # shamt masked


@cocotb.test()
async def sra(dut):
    await _check(dut, ALU_SRA, 0x80000000, 1, 0xC0000000)
    await _check(dut, ALU_SRA, 0x80000000, 31, 0xFFFFFFFF)
    await _check(dut, ALU_SRA, 0x7FFFFFFF, 1, 0x3FFFFFFF)


@cocotb.test()
async def lui(dut):
    await _check(dut, ALU_LUI, 0, 0x12345000, 0x12345000)


@cocotb.test()
async def mul(dut):
    await _check(dut, ALU_MUL, 3, 4, 12)
    await _check(dut, ALU_MUL, 0xFFFFFFFF, 0xFFFFFFFF, 1)      # (-1)*(-1) low


@cocotb.test()
async def mulh(dut):
    # INT_MIN * 2 = -2^32; high half = -1
    await _check(dut, ALU_MULH, 0x80000000, 2, 0xFFFFFFFF)
    # INT_MIN * INT_MIN = 2^62; high half = 0x40000000
    await _check(dut, ALU_MULH, 0x80000000, 0x80000000, 0x40000000)
    await _check(dut, ALU_MULH, 1, 1, 0)


@cocotb.test()
async def mulhu(dut):
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 2, 1)
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE)


@cocotb.test()
async def mulhsu(dut):
    # signed -2^31 * unsigned (2^32-1) = -2^63 + 2^31 = 0x8000_0000_8000_0000
    await _check(dut, ALU_MULHSU, 0x80000000, 0xFFFFFFFF, 0x80000000)
    # (-1) * unsigned -> high half is sign extension
    await _check(dut, ALU_MULHSU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)


@cocotb.test()
async def div_signed(dut):
    await _check(dut, ALU_DIV, 10, 3, 3)
    await _check(dut, ALU_DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)      # -4/2 = -2
    await _check(dut, ALU_DIV, 7, 0xFFFFFFFE, 0xFFFFFFFD)      # 7/-2 = -3 (trunc to 0)


@cocotb.test()
async def div_by_zero(dut):
    await _check(dut, ALU_DIV, 123, 0, 0xFFFFFFFF)
    await _check(dut, ALU_DIV, 0, 0, 0xFFFFFFFF)


@cocotb.test()
async def div_overflow(dut):
    # INT_MIN / -1 -> INT_MIN  (defined overflow per RV32IM)
    await _check(dut, ALU_DIV, 0x80000000, 0xFFFFFFFF, 0x80000000)


@cocotb.test()
async def divu(dut):
    await _check(dut, ALU_DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check(dut, ALU_DIVU, 100, 7, 14)


@cocotb.test()
async def divu_by_zero(dut):
    await _check(dut, ALU_DIVU, 42, 0, 0xFFFFFFFF)


@cocotb.test()
async def rem_signed(dut):
    await _check(dut, ALU_REM, 10, 3, 1)
    # -10 % 3 trunc-to-zero: -10 = (-3)*3 + (-1) -> rem = -1 = 0xFFFFFFFF
    await _check(dut, ALU_REM, 0xFFFFFFF6, 3, 0xFFFFFFFF)
    # 10 % -3 trunc-to-zero: 10 = (-3)*(-3) + 1 -> rem = 1 (sign of dividend)
    await _check(dut, ALU_REM, 10, 0xFFFFFFFD, 1)


@cocotb.test()
async def rem_by_zero(dut):
    await _check(dut, ALU_REM, 0xDEADBEEF, 0, 0xDEADBEEF)


@cocotb.test()
async def rem_overflow(dut):
    # INT_MIN % -1 -> 0
    await _check(dut, ALU_REM, 0x80000000, 0xFFFFFFFF, 0)


@cocotb.test()
async def remu(dut):
    await _check(dut, ALU_REMU, 7, 3, 1)


@cocotb.test()
async def remu_by_zero(dut):
    await _check(dut, ALU_REMU, 0xCAFEBABE, 0, 0xCAFEBABE)


def test_alu_runner():
    """pytest entry — runs every @cocotb.test() above under Verilator."""
    run_cocotb(toplevel="alu",
               sources=["core_pkg.sv", "alu.sv"],
               test_module="test_alu")
