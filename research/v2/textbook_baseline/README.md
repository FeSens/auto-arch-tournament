# Textbook-edit baseline (amendment 15, part B)

V0 with one textbook edit: the single-cycle divider is replaced by an iterative
one. It answers "how far does one well-known design change get, compared with
fifteen rounds of an agent?" Pre-registered in
`research/runs/EXP-2026-09-28-v2-main/amendment_15.yaml` (part B) before the
edit was written.

## The edit

V0 computes DIV/DIVU/REM/REMU with SystemVerilog `/` and `%` in one cycle. On
the Tang Nano 20K that divider is a 150-logic-level path, which is why V0 runs
at 5.4 MHz. The edit:

- `rtl/divider.sv` (new): radix-2 restoring division, one quotient bit per
  cycle. Cycle 0 latches the operand magnitudes and result signs, cycles 1 to 32
  each do one shift-and-subtract step, cycle 33 presents the sign-corrected
  quotient or remainder. Divide by zero is caught at start (quotient all ones,
  remainder = dividend); INT_MIN / -1 comes out of the datapath correctly
  (quotient INT_MIN, remainder 0).
- `rtl/alu.sv`: the `/` and `%` cases are removed; the multiplier is unchanged.
- `rtl/ex_stage.sv`: a divide stays in EX until the divider is done. Its
  operands are latched on its first EX cycle, because the instructions ahead
  drain while it waits and the forwarding paths that fed it disappear. The
  latched values also go to EX/MEM's rs1/rs2 fields (RVFI rs1/rs2_rdata). EX/MEM
  takes bubbles while the divide runs.
- `rtl/hazard_unit.sv`: a divide in progress holds the PC and the ID/EX
  register and sends bubbles into EX/MEM; a data-memory stall still holds
  everything, as in V0.
- `rtl/core.sv`: wiring.

A divide occupies EX for 34 cycles. Nothing else changes: no forwarding,
branch, fetch or memory changes, no Fmax tuning. `rtl.patch` is the full RTL
diff against V0 (fixture tag hwe-bench-v2.8.3), `test.patch` the change to the
existing unit tests.

Written by the operator's coding assistant (Claude Opus 5.5 in Claude Code).
Opus 5.5 is also a scored system; the amendment fixes the edit, the author only
implements it.

## Deviation from the amendment text: divider latency under formal

The amendment says that under `RISCV_FORMAL_ALTOPS` the divider "keeps the same
latency". It cannot: riscv-formal's liveness check (trigger at step 10, check at
step 20 in `formal/checks_si.cfg`) requires the instruction after a retirement
to retire within 10 cycles, so a 34-cycle divide fails it. Under ALTOPS the
divider therefore returns the stand-in formula one cycle after the request (2
cycles in EX), which still exercises the stall, operand latch and bubble path
in formal. This is what the agents' iterative dividers do too (for example
Opus 5.5 rep1 `divider.sv` skips the iterations under ALTOPS; Luna rep1
`ex_stage.sv` removes the stall entirely). The real 34-cycle arithmetic path is
checked by `test/test_divider.py` and by cosim.

## Tests (run 2026-10-04, before any harness eval)

`test/test_divider.py` (new) drives the divider with its request/ack handshake
and checks every result bit-exact against a Python model of the RV32M rules:
the ten V0 division vectors (moved from `test_alu.py`), a back-to-back
sequence, and 160 vectors (40 per op, edge values mixed with random words),
with the operand inputs scrambled while a divide waits, to prove it uses its
latched copy. It also checks the 34-cycle latency. A deliberately broken
remainder sign makes it fail (checked).

All six cocotb suites pass under Verilator: alu 13, decoder 30, divider 12,
imm_gen 8, pipeline 11, reg_file 5 (79 cases). Verilator lint (`-Wall`, the
harness's build gate) is clean.

## Scoring (2026-10-05)

`research/v2/scripts/score_textbook.py`, 10:31Z to 10:39Z, after the amendment 14
runners finished, in scratch trees of the bench-v2.8.3 fixture with the
harness's own evals (formal under the tournament's machine-wide formal lock).
Records: `results/v0.json`, `results/textbook.json`. Both designs pass every
gate: formal 53 of 53, cosim, the CoreMark CRC and UART checks, all five
held-out kernels validated, unit tests (V0 5 suites, textbook 6).

| | V0 | textbook edit |
|---|---|---|
| CoreMark score (iter/s) | 12.1 | 103.7 |
| held-out score (iter/s) | 309 | 2,645 |
| Gowin Fmax (median of 3 placements) | 5.4 MHz | 46.6 MHz |
| CoreMark cycles | 4,491,485 | 4,491,817 |
| LUT4 | 12,312 | 2,541 |
| critical path | 150 levels, MEM to the data-memory port through the combinational divider | 20 levels, register file to the ID/EX rs1 field |
| Artix-7 Fmax (amendment 15 part C flow) | 9.6 MHz | 65.3 MHz |

The whole gain is Fmax (8.6x). The 34-cycle divide costs CoreMark 332 cycles
(0.007%), and the held-out cycle counts are identical to V0's: the five
held-out ELFs contain no divide instruction (GCC turns Dhrystone's division by
a known constant into a multiply), so the held-out score never depends on
divider latency. LUT4 falls by 79% because the combinational divider was most
of V0's logic.

Next to the agents (held-out score, geometric mean of six runs; per-round
champion CoreMark geomean, which round first exceeds 103.7):

| system | final held-out | geomean passes 103.7 at round | runs past 103.7 by round |
|---|---|---|---|
| Opus 5.5 | 7,024 | 1 | 1 to 2 |
| Sonnet 5.5 | 6,418 | 1 | 1 to 2 |
| GPT-6.1 Sol | 5,320 | 2 | 1 to 3 |
| GPT-6 Astra | 5,014 | 3 | 3 to 5 |
| GPT-5.5 | 3,595 | 1 | 1 to 2 |
| GPT-6 Luna | 3,538 | 2 | 1 to 4 |

Every system's final design scores 1.3x (Luna) to 2.7x (Opus) the textbook
edit on held-out, and every scored run beats it (the lowest, Luna rep6, 2,881).
Most first-round agent designs are this edit or close to it (an iterative or
multi-cycle divider). Among the reference cores the textbook edit's held-out
score (2,645) sits between Hazard3 (3,028) and Ibex maxperf (2,595).
