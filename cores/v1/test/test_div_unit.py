"""Unit tests for rtl/div_unit.sv."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from _helpers import (
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    run_cocotb,
)

MASK32 = 0xFFFFFFFF


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    dut.reset.value = 1
    dut.start.value = 0
    dut.op.value = ALU_DIVU
    dut.a.value = 0
    dut.b.value = 1
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


async def _check(dut, op, a, b, expected, max_cycles=40):
    dut.op.value = op
    dut.a.value = a & MASK32
    dut.b.value = b & MASK32
    dut.start.value = 1
    await RisingEdge(dut.clock)
    dut.start.value = 0

    saw_busy = False
    for _ in range(max_cycles):
        await Timer(1, "ns")
        saw_busy = saw_busy or bool(int(dut.busy.value))
        if int(dut.done.value):
            actual = int(dut.result.value) & MASK32
            assert saw_busy, "divider completed without a visible busy cycle"
            assert actual == (expected & MASK32), (
                f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
                f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
            )
            await RisingEdge(dut.clock)
            return
        await RisingEdge(dut.clock)

    raise AssertionError(f"divider did not finish op={op} within {max_cycles} cycles")


@cocotb.test()
async def div_signed(dut):
    await _setup(dut)
    await _check(dut, ALU_DIV, 10, 3, 3)
    await _check(dut, ALU_DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)
    await _check(dut, ALU_DIV, 7, 0xFFFFFFFE, 0xFFFFFFFD)


@cocotb.test()
async def div_by_zero_and_overflow(dut):
    await _setup(dut)
    await _check(dut, ALU_DIV, 123, 0, 0xFFFFFFFF)
    await _check(dut, ALU_DIV, 0, 0, 0xFFFFFFFF)
    await _check(dut, ALU_DIV, 0x80000000, 0xFFFFFFFF, 0x80000000)


@cocotb.test()
async def divu(dut):
    await _setup(dut)
    await _check(dut, ALU_DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check(dut, ALU_DIVU, 100, 7, 14)
    await _check(dut, ALU_DIVU, 42, 0, 0xFFFFFFFF)


@cocotb.test()
async def rem_signed(dut):
    await _setup(dut)
    await _check(dut, ALU_REM, 10, 3, 1)
    await _check(dut, ALU_REM, 0xFFFFFFF6, 3, 0xFFFFFFFF)
    await _check(dut, ALU_REM, 10, 0xFFFFFFFD, 1)
    await _check(dut, ALU_REM, 0xDEADBEEF, 0, 0xDEADBEEF)
    await _check(dut, ALU_REM, 0x80000000, 0xFFFFFFFF, 0)


@cocotb.test()
async def remu_and_back_to_back(dut):
    await _setup(dut)
    await _check(dut, ALU_REMU, 7, 3, 1)
    await _check(dut, ALU_REMU, 0xCAFEBABE, 0, 0xCAFEBABE)
    await _check(dut, ALU_DIVU, 100, 7, 14)
    await _check(dut, ALU_DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check(dut, ALU_DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)
    await _check(dut, ALU_REM, 10, 3, 1)


def test_div_unit_runner():
    run_cocotb(
        toplevel="div_unit",
        sources=["core_pkg.sv", "div_unit.sv"],
        test_module="test_div_unit",
    )
