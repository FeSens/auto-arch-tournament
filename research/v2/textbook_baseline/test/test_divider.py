"""Unit tests for rtl/divider.sv (iterative RV32M divider).

The divider takes a request with op/a/b, raises `done` when the result is
ready (34 cycles after the request is first seen) and holds it until `ack`.
Every result is checked bit-exact against a Python model of the RV32M
rules, including divide by zero and INT_MIN / -1.
"""
from __future__ import annotations

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from _helpers import ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU, run_cocotb

MASK32 = 0xFFFFFFFF
LATENCY = 34  # cycles from the first request cycle to the ack cycle, inclusive


def _s32(x: int) -> int:
    x &= MASK32
    return x - (1 << 32) if x & 0x80000000 else x


def model(op: int, a: int, b: int) -> int:
    """RV32M DIV/DIVU/REM/REMU."""
    a &= MASK32
    b &= MASK32
    if op == ALU_DIVU:
        return MASK32 if b == 0 else a // b
    if op == ALU_REMU:
        return a if b == 0 else a % b
    sa, sb = _s32(a), _s32(b)
    if b == 0:
        return MASK32 if op == ALU_DIV else a
    if sa == -(1 << 31) and sb == -1:
        return 0x80000000 if op == ALU_DIV else 0
    q = abs(sa) // abs(sb)
    if (sa < 0) != (sb < 0):
        q = -q
    if op == ALU_DIV:
        return q & MASK32
    return (sa - q * sb) & MASK32  # remainder takes the dividend's sign


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.req.value = 0
    dut.ack.value = 0
    dut.op.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.reset.value = 1
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


async def _check_div(dut, op, a, b, expected=None):
    """Hold req with the operands until done, check, ack, drop req."""
    if expected is None:
        expected = model(op, a, b)
    dut.op.value = op
    dut.a.value = a & MASK32
    dut.b.value = b & MASK32
    dut.req.value = 1
    dut.ack.value = 0
    cycles = 0
    while True:
        await ReadOnly()
        cycles += 1
        if int(dut.done.value):
            break
        assert cycles < 100, "divider never raised done"
        await RisingEdge(dut.clock)
        # The pipeline keeps EX's operand inputs moving while a divide waits
        # (forwarding sources drain); the divider must use its latched copy.
        dut.a.value = random.getrandbits(32)
        dut.b.value = random.getrandbits(32)
    actual = int(dut.result.value) & MASK32
    assert cycles == LATENCY, f"latency {cycles}, expected {LATENCY}"
    assert actual == (expected & MASK32), (
        f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
    )
    await RisingEdge(dut.clock)
    dut.ack.value = 1
    await RisingEdge(dut.clock)
    dut.ack.value = 0
    dut.req.value = 0


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


EDGE = [0, 1, 2, 3, 7, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF,
        0xFFFFFFFE, 0xFFFF0000, 0x0000FFFF, 0xDEADBEEF, 0x12345678]


@cocotb.test()
async def random_vectors(dut):
    """40 vectors per op (edge values mixed with random words), back to
    back with req held high across ops as in the pipeline."""
    await _setup(dut)
    rng = random.Random(20261004)
    for op in (ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU):
        for i in range(40):
            a = rng.choice(EDGE) if i % 3 == 0 else rng.getrandbits(32)
            b = rng.choice(EDGE) if i % 4 == 1 else rng.getrandbits(rng.choice((4, 12, 32)))
            await _check_div(dut, op, a, b)


def test_divider_runner():
    """pytest entry: runs every @cocotb.test() above under Verilator."""
    run_cocotb(toplevel="divider",
               sources=["core_pkg.sv", "divider.sv"],
               test_module="test_divider")
