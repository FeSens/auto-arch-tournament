"""Unit tests for rtl/alu.sv. Mirrors chisel/test/src/ALUSpec.scala 1:1.

After hyp-20260427-002, DIV/DIVU/REM/REMU run on a multi-cycle iterative
divider exposed via a start_div / div_busy / div_done handshake. Edge
cases (b == 0; signed INT_MIN / -1) still complete combinationally —
the ALU short-circuits the FSM and pulses div_done in the same cycle
start_div is asserted.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from _helpers import (
    ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR,
    ALU_SLT, ALU_SLTU, ALU_SLL, ALU_SRL, ALU_SRA,
    ALU_LUI,
    ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    run_cocotb,
)

MASK32 = 0xFFFFFFFF
DIV_OPS = (ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU)
# 33 cycles for a real iterative divide; some headroom for edge cases.
DIV_TIMEOUT_CYCLES = 40


async def _setup(dut):
    """Start clock + reset divu FSM. Safe to call multiple times — each
    @cocotb.test entry is a fresh simulation, so we always need the
    clock and a clean reset before driving inputs.
    """
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    dut.reset.value     = 1
    dut.start_div.value = 0
    dut.op.value        = 0
    dut.a.value         = 0
    dut.b.value         = 0
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


async def _check(dut, op, a, b, expected):
    """Drive a non-div op and check the combinational result."""
    dut.start_div.value = 0
    dut.op.value = op
    dut.a.value  = a & MASK32
    dut.b.value  = b & MASK32
    await Timer(1, "ns")
    actual = int(dut.out.value) & MASK32
    assert actual == (expected & MASK32), (
        f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
    )


async def _check_div(dut, op, a, b, expected):
    """Drive a DIV/DIVU/REM/REMU op via the start/busy/done handshake.

    Mirrors what ex_stage does: pulse start_div for one cycle, then
    poll for div_done (with a cycle-bounded timeout). For edge cases the
    pulse and the done both land combinationally before any clock edge.
    """
    assert op in DIV_OPS, f"_check_div called with non-div op {op}"

    # Drive operands and start_div.
    dut.op.value        = op
    dut.a.value         = a & MASK32
    dut.b.value         = b & MASK32
    dut.start_div.value = 1
    await Timer(1, "ns")  # let the combinational cone settle

    # Edge cases (b == 0; signed INT_MIN / -1) finish in the same cycle
    # start_div is asserted. Real divides take 33 cycles; poll up to
    # DIV_TIMEOUT_CYCLES with a hard ceiling.
    cycles = 0
    while int(dut.div_done.value) == 0:
        if cycles >= DIV_TIMEOUT_CYCLES:
            raise AssertionError(
                f"div_done never asserted within {DIV_TIMEOUT_CYCLES} cycles "
                f"for op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x}"
            )
        await RisingEdge(dut.clock)
        # Drop start_div after the first edge — the FSM has latched the
        # operands on its IDLE→BUSY transition and start would otherwise
        # re-trigger when divu returns to IDLE post-DONE.
        dut.start_div.value = 0
        await Timer(1, "ns")
        cycles += 1

    actual = int(dut.out.value) & MASK32

    # Retire: drop start_div (idempotent for edge cases) and clock once
    # so the divu FSM falls back to IDLE before the next test vector.
    dut.start_div.value = 0
    await RisingEdge(dut.clock)
    await Timer(1, "ns")

    assert actual == (expected & MASK32), (
        f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
    )


@cocotb.test()
async def add(dut):
    await _setup(dut)
    await _check(dut, ALU_ADD, 5, 3, 8)
    await _check(dut, ALU_ADD, 0xFFFFFFFF, 1, 0)  # wrap


@cocotb.test()
async def sub(dut):
    await _setup(dut)
    await _check(dut, ALU_SUB, 10, 3, 7)
    await _check(dut, ALU_SUB, 0, 1, 0xFFFFFFFF)  # borrow


@cocotb.test()
async def bitwise(dut):
    await _setup(dut)
    await _check(dut, ALU_AND, 0xFF, 0x0F, 0x0F)
    await _check(dut, ALU_OR,  0xF0, 0x0F, 0xFF)
    await _check(dut, ALU_XOR, 0xFF, 0x0F, 0xF0)


@cocotb.test()
async def slt_signed(dut):
    await _setup(dut)
    await _check(dut, ALU_SLT, 0xFFFFFFFF, 0, 1)              # -1 < 0
    await _check(dut, ALU_SLT, 1, 0, 0)
    await _check(dut, ALU_SLT, 0x7FFFFFFF, 0x80000000, 0)     # MAX > MIN


@cocotb.test()
async def sltu_unsigned(dut):
    await _setup(dut)
    await _check(dut, ALU_SLTU, 0xFFFFFFFF, 0, 0)             # max > 0
    await _check(dut, ALU_SLTU, 0, 1, 1)


@cocotb.test()
async def sll(dut):
    await _setup(dut)
    await _check(dut, ALU_SLL, 1, 4, 16)
    await _check(dut, ALU_SLL, 1, 31, 0x80000000)
    await _check(dut, ALU_SLL, 1, 0x20, 1)                    # shamt = b[4:0] = 0


@cocotb.test()
async def srl(dut):
    await _setup(dut)
    await _check(dut, ALU_SRL, 0x80000000, 1, 0x40000000)
    await _check(dut, ALU_SRL, 0x80000000, 31, 1)
    await _check(dut, ALU_SRL, 0xFFFFFFFF, 0x25, 0x07FFFFFF)   # shamt masked


@cocotb.test()
async def sra(dut):
    await _setup(dut)
    await _check(dut, ALU_SRA, 0x80000000, 1, 0xC0000000)
    await _check(dut, ALU_SRA, 0x80000000, 31, 0xFFFFFFFF)
    await _check(dut, ALU_SRA, 0x7FFFFFFF, 1, 0x3FFFFFFF)


@cocotb.test()
async def lui(dut):
    await _setup(dut)
    await _check(dut, ALU_LUI, 0, 0x12345000, 0x12345000)


@cocotb.test()
async def mul(dut):
    await _setup(dut)
    await _check(dut, ALU_MUL, 3, 4, 12)
    await _check(dut, ALU_MUL, 0xFFFFFFFF, 0xFFFFFFFF, 1)      # (-1)*(-1) low


@cocotb.test()
async def mulh(dut):
    await _setup(dut)
    # INT_MIN * 2 = -2^32; high half = -1
    await _check(dut, ALU_MULH, 0x80000000, 2, 0xFFFFFFFF)
    # INT_MIN * INT_MIN = 2^62; high half = 0x40000000
    await _check(dut, ALU_MULH, 0x80000000, 0x80000000, 0x40000000)
    await _check(dut, ALU_MULH, 1, 1, 0)


@cocotb.test()
async def mulhu(dut):
    await _setup(dut)
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 2, 1)
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE)


@cocotb.test()
async def mulhsu(dut):
    await _setup(dut)
    # signed -2^31 * unsigned (2^32-1) = -2^63 + 2^31 = 0x8000_0000_8000_0000
    await _check(dut, ALU_MULHSU, 0x80000000, 0xFFFFFFFF, 0x80000000)
    # (-1) * unsigned -> high half is sign extension
    await _check(dut, ALU_MULHSU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)


@cocotb.test()
async def div_signed(dut):
    await _setup(dut)
    await _check_div(dut, ALU_DIV, 10, 3, 3)
    await _check_div(dut, ALU_DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)      # -4/2 = -2
    await _check_div(dut, ALU_DIV, 7, 0xFFFFFFFE, 0xFFFFFFFD)      # 7/-2 = -3 (trunc to 0)


@cocotb.test()
async def div_by_zero(dut):
    await _setup(dut)
    await _check_div(dut, ALU_DIV, 123, 0, 0xFFFFFFFF)
    await _check_div(dut, ALU_DIV, 0, 0, 0xFFFFFFFF)


@cocotb.test()
async def div_overflow(dut):
    await _setup(dut)
    # INT_MIN / -1 -> INT_MIN  (defined overflow per RV32IM)
    await _check_div(dut, ALU_DIV, 0x80000000, 0xFFFFFFFF, 0x80000000)


@cocotb.test()
async def divu(dut):
    await _setup(dut)
    await _check_div(dut, ALU_DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check_div(dut, ALU_DIVU, 100, 7, 14)


@cocotb.test()
async def divu_by_zero(dut):
    await _setup(dut)
    await _check_div(dut, ALU_DIVU, 42, 0, 0xFFFFFFFF)


@cocotb.test()
async def rem_signed(dut):
    await _setup(dut)
    await _check_div(dut, ALU_REM, 10, 3, 1)
    # -10 % 3 trunc-to-zero: -10 = (-3)*3 + (-1) -> rem = -1 = 0xFFFFFFFF
    await _check_div(dut, ALU_REM, 0xFFFFFFF6, 3, 0xFFFFFFFF)
    # 10 % -3 trunc-to-zero: 10 = (-3)*(-3) + 1 -> rem = 1 (sign of dividend)
    await _check_div(dut, ALU_REM, 10, 0xFFFFFFFD, 1)


@cocotb.test()
async def rem_by_zero(dut):
    await _setup(dut)
    await _check_div(dut, ALU_REM, 0xDEADBEEF, 0, 0xDEADBEEF)


@cocotb.test()
async def rem_overflow(dut):
    await _setup(dut)
    # INT_MIN % -1 -> 0
    await _check_div(dut, ALU_REM, 0x80000000, 0xFFFFFFFF, 0)


@cocotb.test()
async def remu(dut):
    await _setup(dut)
    await _check_div(dut, ALU_REMU, 7, 3, 1)


@cocotb.test()
async def remu_by_zero(dut):
    await _setup(dut)
    await _check_div(dut, ALU_REMU, 0xCAFEBABE, 0, 0xCAFEBABE)


@cocotb.test()
async def back_to_back_divides(dut):
    """Verify the FSM resets cleanly between consecutive iterative
    divides — no carry-over of operands or state from the previous op.
    """
    await _setup(dut)
    # Real divides only (avoid edge-case short-circuit) so each pass
    # exercises the full 33-cycle FSM.
    await _check_div(dut, ALU_DIVU, 100, 7, 14)
    await _check_div(dut, ALU_DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check_div(dut, ALU_DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)  # -4/2 = -2
    await _check_div(dut, ALU_REM, 10, 3, 1)
    await _check_div(dut, ALU_REMU, 7, 3, 1)


def test_alu_runner():
    """pytest entry — runs every @cocotb.test() above under Verilator."""
    run_cocotb(toplevel="alu",
               sources=["core_pkg.sv", "divu.sv", "alu.sv"],
               test_module="test_alu")
