"""Unit tests for rtl/reg_file.sv. Covers x0 hardwiring, write-first
bypass, and the synchronous-reset-clears-all property."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from _helpers import run_cocotb


async def _reset(dut):
    dut.reset.value    = 1
    dut.w_en.value     = 0
    dut.w_addr.value   = 0
    dut.w_data.value   = 0
    dut.rs1_addr.value = 0
    dut.rs2_addr.value = 0
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)


async def _write(dut, addr, data):
    dut.w_en.value   = 1
    dut.w_addr.value = addr
    dut.w_data.value = data
    await RisingEdge(dut.clock)
    dut.w_en.value = 0


async def _read(dut, rs1, rs2):
    dut.rs1_addr.value = rs1
    dut.rs2_addr.value = rs2
    await Timer(1, "ns")
    return int(dut.rs1_data.value), int(dut.rs2_data.value)


@cocotb.test()
async def reset_clears_all(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    await _reset(dut)
    for r in range(32):
        rs1, _ = await _read(dut, r, 0)
        assert rs1 == 0, f"x{r} after reset = 0x{rs1:08x}"


@cocotb.test()
async def write_and_read(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    await _reset(dut)
    await _write(dut, 5, 0xDEADBEEF)
    await Timer(1, "ns")
    rs1, _ = await _read(dut, 5, 0)
    assert rs1 == 0xDEADBEEF


@cocotb.test()
async def x0_hardwired(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    await _reset(dut)
    await _write(dut, 0, 0xCAFEBABE)
    await Timer(1, "ns")
    rs1, _ = await _read(dut, 0, 0)
    assert rs1 == 0


@cocotb.test()
async def write_first_bypass(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    await _reset(dut)
    # Combinational read of an addr that is being written this cycle:
    # bypass returns the new write data.
    dut.rs1_addr.value = 7
    dut.w_en.value     = 1
    dut.w_addr.value   = 7
    dut.w_data.value   = 0x12345678
    await Timer(1, "ns")
    assert int(dut.rs1_data.value) == 0x12345678
    dut.w_en.value = 0


@cocotb.test()
async def two_read_ports(dut):
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    await _reset(dut)
    await _write(dut, 1, 0xAAAAAAAA)
    await _write(dut, 2, 0xBBBBBBBB)
    await Timer(1, "ns")
    rs1, rs2 = await _read(dut, 1, 2)
    assert rs1 == 0xAAAAAAAA
    assert rs2 == 0xBBBBBBBB


def test_reg_file_runner():
    run_cocotb(toplevel="reg_file",
               sources=["reg_file.sv"],
               test_module="test_reg_file")
