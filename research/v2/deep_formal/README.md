# Deep formal (real M-extension arithmetic), post-campaign item 1

The per-round formal gate defines `RISCV_FORMAL_ALTOPS`: riscv-formal and the
design both replace MUL/MULH*/DIV*/REM* with simple stand-in formulas, so the
gate proves operand routing, forwarding, stalls and trap behavior for these
instructions but not the arithmetic. `deep_formal.py` runs the eight RV32M
instruction checks without ALTOPS on a design's final RTL, in a private tree
of the 2.8.4 fixture (the vendored riscv-formal checkout is never written).
Usage and outcome definitions are in the script's docstring.

## Spec defect in the vendored riscv-formal

At the vendored commit (2aa7b49), `insns/insn_div.v` and `insns/insn_rem.v`
compute the signed result inside a conditional whose other arms are unsigned:

    rs2 == 0 ? <all ones> : <overflow case> ? <INT_MIN> : $signed(a) / $signed(b)

Verilog makes the whole conditional unsigned and propagates that into the
division, so the spec computes the unsigned quotient and remainder. Yosys
`eval` of DIV 0xffd47ff1 / 0xad8887ff gives 1 as written and 0 (the RV32M
answer) with the division wrapped in `$unsigned(...)`. The driver applies that
wrap in its private copy (recorded in each result's `spec_fix`). Without it,
`make formal-deep` (`formal/checks-deep.cfg`) fails DIV and REM on every
correct divider.

## Pilot: Opus 5.5 rep1 (`results/`)

| check | depth 20 | depth 48, vendored spec | depth 48, fixed spec |
|---|---|---|---|
| MUL | PASS, 3 s | | |
| MULH, MULHSU, MULHU | TIMEOUT, 2 h | | |
| DIV | PREUNSAT | FAIL, 219 s (spec defect: design 0, spec 1) | TIMEOUT, 4 h |
| REM | PREUNSAT | FAIL, 323 s (spec defect) | TIMEOUT, 4 h |
| DIVU | PREUNSAT | PASS, 6,852 s | |
| REMU | PREUNSAT | TIMEOUT, 4 h | |

PREUNSAT at depth 20: the design's divider takes 35 cycles in EX, so no
divide can retire at the check cycle and the check is vacuous. Depth 48
covers the latency.

Two of eight instructions are proven for one design in about 2 h of solver
time; the rest do not finish in 2 to 4 h each. Running all 36 finals is out
of reach with this flow, so the item stops at the pilot. Real arithmetic stays
covered by cosim (every retired M instruction compared with the Python ISS,
including the gate's edge-value M-op trace) and the cocotb ALU tests. A flow
that can prove it needs the spec fix plus a cheaper method (for example
proving the arithmetic unit alone against the spec, separate from the
pipeline); V3 item 17.
