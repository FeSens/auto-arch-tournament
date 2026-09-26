"""Unit tests for rtl/alu.sv and rtl/div_unit.sv (RV32IM arithmetic).

Two DUTs, two pytest runners, one module (CLAUDE.md invariant 5b keeps
all M-extension arithmetic coverage in this file):

  - `alu` (test_alu_runner): purely combinational RV32I ops plus the four
    MUL variants. No clock, reset, or handshake.
  - `div_unit` (test_div_unit_runner): the multi-cycle DIV / DIVU / REM /
    REMU unit. Driven through its start / done / ack handshake.

Every cocotb test is tagged with the toplevel it targets and is skipped
under the other runner (COCOTB_TOPLEVEL is set by the cocotb runner).
"""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

from _helpers import (
    ALU_ADD, ALU_SUB, ALU_AND, ALU_OR, ALU_XOR,
    ALU_SLT, ALU_SLTU, ALU_SLL, ALU_SRL, ALU_SRA,
    ALU_LUI,
    ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU,
    ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU,
    run_cocotb,
)

MASK32 = 0xFFFFFFFF
INT_MIN = 0x80000000

_TOPLEVEL = os.environ.get("COCOTB_TOPLEVEL", "")


def alu_test(fn):
    return cocotb.test(skip=_TOPLEVEL != "alu")(fn)


def div_test(fn):
    return cocotb.test(skip=_TOPLEVEL != "div_unit")(fn)


# ── RV32M reference model ─────────────────────────────────────────────────
def _s32(x):
    x &= MASK32
    return x - (1 << 32) if x & 0x80000000 else x


def ref_mul(a, b):    return (a * b) & MASK32
def ref_mulh(a, b):   return ((_s32(a) * _s32(b)) >> 32) & MASK32
def ref_mulhu(a, b):  return ((a * b) >> 32) & MASK32
def ref_mulhsu(a, b): return ((_s32(a) * b) >> 32) & MASK32


def ref_div(a, b):
    sa, sb = _s32(a), _s32(b)
    if sb == 0:
        return MASK32
    if sa == -(1 << 31) and sb == -1:
        return INT_MIN
    q = abs(sa) // abs(sb)
    return (-q if (sa < 0) != (sb < 0) else q) & MASK32


def ref_divu(a, b):
    return MASK32 if b == 0 else (a // b) & MASK32


def ref_rem(a, b):
    sa, sb = _s32(a), _s32(b)
    if sb == 0:
        return a & MASK32
    if sa == -(1 << 31) and sb == -1:
        return 0
    r = abs(sa) % abs(sb)
    return (-r if sa < 0 else r) & MASK32


def ref_remu(a, b):
    return a & MASK32 if b == 0 else (a % b) & MASK32


# Operand corner set shared by the M-ext vector generators.
_CORNERS = [
    0x00000000, 0x00000001, 0x00000002, 0x00000003, 0x00000007,
    0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE,
    0xFFFFFFFD, 0x0000FFFF, 0xFFFF0000, 0x12345678, 0xDEADBEEF,
]


def _vectors(seed, n_random=24):
    """Corner pairs + random pairs; always >= 30 per op."""
    rng = random.Random(seed)
    pairs = [
        (0, 0), (123, 0), (0xDEADBEEF, 0), (0x80000000, 0),   # x / 0
        (0x80000000, 0xFFFFFFFF),                             # INT_MIN / -1
        (0x80000000, 1), (0x80000000, 0x80000000),
        (10, 3), (0xFFFFFFF6, 3), (10, 0xFFFFFFFD),           # sign rules
        (0xFFFFFFF6, 0xFFFFFFFD), (7, 0xFFFFFFFE),
        (0xFFFFFFFC, 2), (0xFFFFFFFF, 2), (100, 7), (7, 100),
        (0x7FFFFFFF, 0x7FFFFFFF), (0xFFFFFFFF, 0xFFFFFFFF),
        (0x7FFFFFFF, 0xFFFFFFFF), (1, 0xFFFFFFFF),
    ]
    for _ in range(n_random):
        a = rng.choice(_CORNERS) if rng.random() < 0.25 else rng.getrandbits(32)
        # Mix small, full-width and corner divisors.
        r = rng.random()
        if r < 0.3:
            b = rng.getrandbits(rng.randint(1, 12))
        elif r < 0.45:
            b = rng.choice(_CORNERS)
        else:
            b = rng.getrandbits(32)
        if rng.random() < 0.3:
            b = (-b) & MASK32
        pairs.append((a, b))
    return pairs


# ══════════════════════════════════════════════════════════════════════════
# Combinational ALU (toplevel = alu)
# ══════════════════════════════════════════════════════════════════════════
async def _check(dut, op, a, b, expected):
    """Drive op/a/b and check the combinational result."""
    dut.op.value = op
    dut.a.value  = a & MASK32
    dut.b.value  = b & MASK32
    await Timer(1, "ns")
    actual = int(dut.out.value) & MASK32
    assert actual == (expected & MASK32), (
        f"op={op} a=0x{a & MASK32:08x} b=0x{b & MASK32:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{actual:08x}"
    )


@alu_test
async def add(dut):
    await _check(dut, ALU_ADD, 5, 3, 8)
    await _check(dut, ALU_ADD, 0xFFFFFFFF, 1, 0)  # wrap


@alu_test
async def sub(dut):
    await _check(dut, ALU_SUB, 10, 3, 7)
    await _check(dut, ALU_SUB, 0, 1, 0xFFFFFFFF)  # borrow


@alu_test
async def bitwise(dut):
    await _check(dut, ALU_AND, 0xFF, 0x0F, 0x0F)
    await _check(dut, ALU_OR,  0xF0, 0x0F, 0xFF)
    await _check(dut, ALU_XOR, 0xFF, 0x0F, 0xF0)


@alu_test
async def slt_signed(dut):
    await _check(dut, ALU_SLT, 0xFFFFFFFF, 0, 1)              # -1 < 0
    await _check(dut, ALU_SLT, 1, 0, 0)
    await _check(dut, ALU_SLT, 0x7FFFFFFF, 0x80000000, 0)     # MAX > MIN


@alu_test
async def sltu_unsigned(dut):
    await _check(dut, ALU_SLTU, 0xFFFFFFFF, 0, 0)             # max > 0
    await _check(dut, ALU_SLTU, 0, 1, 1)


@alu_test
async def sll(dut):
    await _check(dut, ALU_SLL, 1, 4, 16)
    await _check(dut, ALU_SLL, 1, 31, 0x80000000)
    await _check(dut, ALU_SLL, 1, 0x20, 1)                    # shamt = b[4:0] = 0


@alu_test
async def srl(dut):
    await _check(dut, ALU_SRL, 0x80000000, 1, 0x40000000)
    await _check(dut, ALU_SRL, 0x80000000, 31, 1)
    await _check(dut, ALU_SRL, 0xFFFFFFFF, 0x25, 0x07FFFFFF)   # shamt masked


@alu_test
async def sra(dut):
    await _check(dut, ALU_SRA, 0x80000000, 1, 0xC0000000)
    await _check(dut, ALU_SRA, 0x80000000, 31, 0xFFFFFFFF)
    await _check(dut, ALU_SRA, 0x7FFFFFFF, 1, 0x3FFFFFFF)


@alu_test
async def lui(dut):
    await _check(dut, ALU_LUI, 0, 0x12345000, 0x12345000)


@alu_test
async def mul(dut):
    await _check(dut, ALU_MUL, 3, 4, 12)
    await _check(dut, ALU_MUL, 0xFFFFFFFF, 0xFFFFFFFF, 1)      # (-1)*(-1) low


@alu_test
async def mulh(dut):
    # INT_MIN * 2 = -2^32; high half = -1
    await _check(dut, ALU_MULH, 0x80000000, 2, 0xFFFFFFFF)
    # INT_MIN * INT_MIN = 2^62; high half = 0x40000000
    await _check(dut, ALU_MULH, 0x80000000, 0x80000000, 0x40000000)
    await _check(dut, ALU_MULH, 1, 1, 0)


@alu_test
async def mulhu(dut):
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 2, 1)
    await _check(dut, ALU_MULHU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE)


@alu_test
async def mulhsu(dut):
    # signed -2^31 * unsigned (2^32-1) = -2^63 + 2^31 = 0x8000_0000_8000_0000
    await _check(dut, ALU_MULHSU, 0x80000000, 0xFFFFFFFF, 0x80000000)
    # (-1) * unsigned -> high half is sign extension
    await _check(dut, ALU_MULHSU, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)


@alu_test
async def mul_vectors(dut):
    """30+ reference-model vectors per MUL variant."""
    for op, ref, seed in [
        (ALU_MUL,    ref_mul,    11),
        (ALU_MULH,   ref_mulh,   12),
        (ALU_MULHU,  ref_mulhu,  13),
        (ALU_MULHSU, ref_mulhsu, 14),
    ]:
        vecs = _vectors(seed)
        assert len(vecs) >= 30
        for a, b in vecs:
            await _check(dut, op, a, b, ref(a, b))


# ── Shared-datapath corners ───────────────────────────────────────────────
# ADD/SUB/SLT/SLTU share one 33-bit adder (SLT from its sign bit, SLTU from
# its carry) and the four MUL variants share one signed 33x33 product, so
# these pin the sign/carry and operand-extension edges.
_SLT_PAIRS = [
    (0x80000000, 0x7FFFFFFF), (0x7FFFFFFF, 0x80000000),   # MIN vs MAX
    (0x80000000, 0x80000000), (0x7FFFFFFF, 0x7FFFFFFF),   # equal
    (0, 0), (0xFFFFFFFF, 0xFFFFFFFF),
    (0xFFFFFFFF, 0), (0, 0xFFFFFFFF),
    (0x80000000, 0), (0, 0x80000000),
    (0x80000000, 0xFFFFFFFF), (0xFFFFFFFF, 0x80000000),
    (0x7FFFFFFF, 0), (0, 0x7FFFFFFF),
    (0xFFFFFFFE, 0xFFFFFFFF), (0xFFFFFFFF, 0xFFFFFFFE),
    (1, 2), (2, 1), (0x80000001, 0x80000000),
]


@alu_test
async def slt_sltu_corners(dut):
    for a, b in _SLT_PAIRS:
        await _check(dut, ALU_SLT, a, b, int(_s32(a) < _s32(b)))
        await _check(dut, ALU_SLTU, a, b, int(a < b))


@alu_test
async def add_sub_corners(dut):
    for a, b in _SLT_PAIRS + [(0, 1), (1, 0), (0x80000000, 1),
                              (0x7FFFFFFF, 1), (0xFFFFFFFF, 1)]:
        await _check(dut, ALU_ADD, a, b, (a + b) & MASK32)
        await _check(dut, ALU_SUB, a, b, (a - b) & MASK32)


@alu_test
async def mul_high_corners(dut):
    pairs = [
        (INT_MIN, INT_MIN), (0xFFFFFFFF, 0xFFFFFFFF),
        (INT_MIN, 0xFFFFFFFF), (0xFFFFFFFF, INT_MIN),
        (0x7FFFFFFF, INT_MIN), (INT_MIN, 0x7FFFFFFF),
        (0x7FFFFFFF, 0x7FFFFFFF), (0x7FFFFFFF, 0xFFFFFFFF),
        (0xFFFFFFFF, 0x7FFFFFFF), (0, 0xFFFFFFFF), (0xFFFFFFFF, 0),
        (1, 0xFFFFFFFF), (0xFFFFFFFF, 1),
    ]
    for op, ref in [(ALU_MUL, ref_mul), (ALU_MULH, ref_mulh),
                    (ALU_MULHU, ref_mulhu), (ALU_MULHSU, ref_mulhsu)]:
        for a, b in pairs:
            await _check(dut, op, a, b, ref(a, b))


# RV32I reference for every non-M op. A wrong or overlapping one-hot select
# in the AND-OR result merge shows up here as a stray OR'd-in term.
_RV32I_REF = {
    ALU_ADD:  lambda a, b: a + b,
    ALU_SUB:  lambda a, b: a - b,
    ALU_AND:  lambda a, b: a & b,
    ALU_OR:   lambda a, b: a | b,
    ALU_XOR:  lambda a, b: a ^ b,
    ALU_SLT:  lambda a, b: int(_s32(a) < _s32(b)),
    ALU_SLTU: lambda a, b: int(a < b),
    ALU_SLL:  lambda a, b: a << (b & 31),
    ALU_SRL:  lambda a, b: a >> (b & 31),
    ALU_SRA:  lambda a, b: _s32(a) >> (b & 31),
    ALU_LUI:  lambda a, b: b,
}


@alu_test
async def rv32i_vectors(dut):
    rng = random.Random(31)
    pairs = [(a, b) for a in _CORNERS for b in _CORNERS[::3]]
    pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(40)]
    pairs += [(rng.getrandbits(32), rng.getrandbits(6)) for _ in range(20)]
    for op, ref in _RV32I_REF.items():
        for a, b in pairs:
            await _check(dut, op, a, b, ref(a, b) & MASK32)


@alu_test
async def div_ops_output_zero(dut):
    """DIV/DIVU/REM/REMU run in div_unit; the ALU selects nothing for them."""
    for op in (ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU):
        for a, b in [(0xFFFFFFFF, 0xFFFFFFFF), (0x12345678, 3), (7, 0)]:
            await _check(dut, op, a, b, 0)


# ══════════════════════════════════════════════════════════════════════════
# Multi-cycle divide unit (toplevel = div_unit)
# ══════════════════════════════════════════════════════════════════════════
# (is_rem, is_unsigned) per op = funct3[1:0] of DIV/DIVU/REM/REMU.
DIV, DIVU, REM, REMU = (0, 0), (0, 1), (1, 0), (1, 1)
_DIV_REF = {DIV: ref_div, DIVU: ref_divu, REM: ref_rem, REMU: ref_remu}
_DIV_NAME = {DIV: "DIV", DIVU: "DIVU", REM: "REM", REMU: "REMU"}

# start -> done is 34 cycles today (1 latch + 1 prep + 32 steps + 1 fixup
# - 1). Bound it so a stuck / runaway FSM fails loudly.
_DIV_MAX_CYCLES = 40


async def _div_setup(dut):
    """Start the clock and hold reset for a few cycles. Inputs are driven
    on falling edges so every rising edge samples settled values."""
    cocotb.start_soon(Clock(dut.clock, 10, "ns").start())
    dut.reset.value       = 1
    dut.start.value       = 0
    dut.ack.value         = 0
    dut.is_rem.value      = 0
    dut.is_unsigned.value = 0
    dut.a.value           = 0
    dut.b.value           = 0
    for _ in range(3):
        await FallingEdge(dut.clock)
    dut.reset.value = 0
    await FallingEdge(dut.clock)
    assert int(dut.busy.value) == 0 and int(dut.done.value) == 0


async def _div_launch(dut, op, a, b):
    """Pulse start for one cycle with (op, a, b), then scramble the
    operand inputs: the unit must work from its launch-time latch."""
    is_rem, is_uns = op
    dut.is_rem.value      = is_rem
    dut.is_unsigned.value = is_uns
    dut.a.value           = a & MASK32
    dut.b.value           = b & MASK32
    dut.start.value       = 1
    await FallingEdge(dut.clock)
    dut.start.value       = 0
    dut.a.value           = (~a) & MASK32
    dut.b.value           = (a ^ b ^ 0x5A5A5A5A) & MASK32
    dut.is_rem.value      = 1 - is_rem
    dut.is_unsigned.value = 1 - is_uns


async def _div_wait_done(dut):
    """Return the number of cycles from the start edge until done."""
    cycles = 1
    while int(dut.done.value) == 0:
        assert int(dut.busy.value) == 1, "divider idle before done"
        await FallingEdge(dut.clock)
        cycles += 1
        assert cycles <= _DIV_MAX_CYCLES, "divider never raised done"
    assert int(dut.busy.value) == 0, "busy and done both high"
    return cycles


async def _div_ack(dut):
    dut.ack.value = 1
    await FallingEdge(dut.clock)
    dut.ack.value = 0
    assert int(dut.done.value) == 0, "done must clear after ack"
    assert int(dut.busy.value) == 0, "unit must return to idle after ack"


async def _check_div(dut, op, a, b, expected=None):
    a &= MASK32
    b &= MASK32
    if expected is None:
        expected = _DIV_REF[op](a, b)
    await _div_launch(dut, op, a, b)
    await _div_wait_done(dut)
    got = int(dut.result.value) & MASK32
    assert got == (expected & MASK32), (
        f"{_DIV_NAME[op]} a=0x{a:08x} b=0x{b:08x} "
        f"expected=0x{expected & MASK32:08x} got=0x{got:08x}"
    )
    # Launch-time operands stay visible for RVFI rs1/rs2_rdata.
    assert int(dut.a_lat.value) == a, "a_lat must hold the launch operand"
    assert int(dut.b_lat.value) == b, "b_lat must hold the launch operand"
    await _div_ack(dut)


@div_test
async def div_signed(dut):
    await _div_setup(dut)
    await _check_div(dut, DIV, 10, 3, 3)
    await _check_div(dut, DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)      # -4/2 = -2
    await _check_div(dut, DIV, 7, 0xFFFFFFFE, 0xFFFFFFFD)      # 7/-2 = -3 (trunc to 0)


@div_test
async def div_by_zero(dut):
    await _div_setup(dut)
    await _check_div(dut, DIV, 123, 0, 0xFFFFFFFF)
    await _check_div(dut, DIV, 0, 0, 0xFFFFFFFF)
    await _check_div(dut, DIV, 0xFFFFFF85, 0, 0xFFFFFFFF)      # -123/0 = -1
    await _check_div(dut, DIV, 0x80000000, 0, 0xFFFFFFFF)


@div_test
async def div_overflow(dut):
    await _div_setup(dut)
    # INT_MIN / -1 -> INT_MIN  (defined overflow per RV32IM)
    await _check_div(dut, DIV, 0x80000000, 0xFFFFFFFF, 0x80000000)


@div_test
async def divu(dut):
    await _div_setup(dut)
    await _check_div(dut, DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check_div(dut, DIVU, 100, 7, 14)
    await _check_div(dut, DIVU, 0x80000000, 0xFFFFFFFF, 0)     # no signed overflow


@div_test
async def divu_by_zero(dut):
    await _div_setup(dut)
    await _check_div(dut, DIVU, 42, 0, 0xFFFFFFFF)
    await _check_div(dut, DIVU, 0xFFFFFFFF, 0, 0xFFFFFFFF)


@div_test
async def rem_signed(dut):
    await _div_setup(dut)
    await _check_div(dut, REM, 10, 3, 1)
    # -10 % 3 trunc-to-zero: -10 = (-3)*3 + (-1) -> rem = -1 = 0xFFFFFFFF
    await _check_div(dut, REM, 0xFFFFFFF6, 3, 0xFFFFFFFF)
    # 10 % -3 trunc-to-zero: 10 = (-3)*(-3) + 1 -> rem = 1 (sign of dividend)
    await _check_div(dut, REM, 10, 0xFFFFFFFD, 1)
    # -10 % -3 -> -1 (sign of dividend)
    await _check_div(dut, REM, 0xFFFFFFF6, 0xFFFFFFFD, 0xFFFFFFFF)


@div_test
async def rem_by_zero(dut):
    await _div_setup(dut)
    await _check_div(dut, REM, 0xDEADBEEF, 0, 0xDEADBEEF)
    await _check_div(dut, REM, 0x80000000, 0, 0x80000000)
    await _check_div(dut, REM, 5, 0, 5)


@div_test
async def rem_overflow(dut):
    await _div_setup(dut)
    # INT_MIN % -1 -> 0
    await _check_div(dut, REM, 0x80000000, 0xFFFFFFFF, 0)


@div_test
async def remu(dut):
    await _div_setup(dut)
    await _check_div(dut, REMU, 7, 3, 1)
    await _check_div(dut, REMU, 0x80000000, 0xFFFFFFFF, 0x80000000)


@div_test
async def remu_by_zero(dut):
    await _div_setup(dut)
    await _check_div(dut, REMU, 0xCAFEBABE, 0, 0xCAFEBABE)


@div_test
async def div_vectors(dut):
    """30+ reference-model vectors per DIV/DIVU/REM/REMU (corners + random)."""
    await _div_setup(dut)
    for op, seed in [(DIV, 21), (DIVU, 22), (REM, 23), (REMU, 24)]:
        vecs = _vectors(seed)
        assert len(vecs) >= 30
        for a, b in vecs:
            await _check_div(dut, op, a, b)


@div_test
async def back_to_back_divides(dut):
    """The FSM must reset cleanly between consecutive divides — no carry-over
    of operands, sign flags, or partial remainder from the previous op."""
    await _div_setup(dut)
    await _check_div(dut, DIVU, 100, 7, 14)
    await _check_div(dut, DIVU, 0xFFFFFFFF, 2, 0x7FFFFFFF)
    await _check_div(dut, DIV, 0xFFFFFFFC, 2, 0xFFFFFFFE)       # -4/2 = -2
    await _check_div(dut, REM, 0xFFFFFFF6, 3, 0xFFFFFFFF)
    await _check_div(dut, REM, 10, 3, 1)
    await _check_div(dut, REMU, 7, 3, 1)
    await _check_div(dut, DIV, 123, 0, 0xFFFFFFFF)
    await _check_div(dut, DIVU, 100, 7, 14)


@div_test
async def latency_bound(dut):
    """start -> done within the documented bound, and busy the whole way."""
    await _div_setup(dut)
    for op, a, b in [(DIVU, 0xFFFFFFFF, 1), (REM, 0x80000000, 0xFFFFFFFF),
                     (DIV, 5, 0)]:
        await _div_launch(dut, op, a, b)
        cycles = await _div_wait_done(dut)
        assert 2 <= cycles <= _DIV_MAX_CYCLES, f"latency {cycles} out of range"
        assert int(dut.result.value) == _DIV_REF[op](a, b)
        await _div_ack(dut)


@div_test
async def done_sticky_until_ack(dut):
    """done + result hold while ack stays low (EX/MEM stalled on dmem)."""
    await _div_setup(dut)
    await _div_launch(dut, DIV, 0xFFFFFF9C, 7)                  # -100/7 = -14
    await _div_wait_done(dut)
    for _ in range(5):
        assert int(dut.done.value) == 1
        assert int(dut.result.value) == ref_div(0xFFFFFF9C, 7)
        await FallingEdge(dut.clock)
    await _div_ack(dut)


@div_test
async def start_ignored_while_busy(dut):
    """A start pulse mid-divide (or while done) must not disturb the op."""
    await _div_setup(dut)
    await _div_launch(dut, REMU, 1000, 33)
    for _ in range(5):
        await FallingEdge(dut.clock)
    dut.start.value = 1
    dut.a.value     = 0xFFFFFFFF
    dut.b.value     = 1
    await FallingEdge(dut.clock)
    dut.start.value = 0
    await _div_wait_done(dut)
    dut.start.value = 1                                          # while DONE
    await FallingEdge(dut.clock)
    dut.start.value = 0
    assert int(dut.done.value) == 1
    assert int(dut.result.value) == 1000 % 33
    assert int(dut.a_lat.value) == 1000 and int(dut.b_lat.value) == 33
    await _div_ack(dut)


def test_alu_runner():
    """pytest entry — combinational ALU tests under Verilator."""
    run_cocotb(toplevel="alu",
               sources=["core_pkg.sv", "alu.sv"],
               test_module="test_alu")


def test_div_unit_runner():
    """pytest entry — multi-cycle divide unit tests under Verilator."""
    run_cocotb(toplevel="div_unit",
               sources=["core_pkg.sv", "div_unit.sv"],
               test_module="test_alu")
