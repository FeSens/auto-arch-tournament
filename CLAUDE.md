# CLAUDE.md — non-negotiable invariants and don't-touch list

Every item below was a real bug in the prior Chisel iteration. Each must be
enforced by a check that fails loudly when violated. **Do not weaken these
checks** to make a hypothesis pass.

## Hard invariants

| # | Invariant                                                                                                  | Enforced by                                  |
|---|------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| 1 | Top module `core` exposes a 2-channel RVFI port set: every `io_rvfi_<field>` has `_0` and `_1` variants of the same width as its scalar predecessor. Channel 0 carries the older of two simultaneous retirements; channel 1 the younger. Single-retire cycles MUST place the retirement on channel 0 with `io_rvfi_valid_1 = 0`. All channel-1 ports MUST be driven (no X/Z); tie unused fields to `'0`. | cocotb smoke test, `riscv-formal` wrapper at NRET=2 |
| 2 | `rvfi_trap = 1` iff the retiring instruction is illegal per RV32IM (decoder default = illegal)             | `riscv-formal ill` check                     |
| 3 | EBREAK is the *only* SYSTEM (opcode `0x73`) instruction the core treats as valid; ECALL / CSR / MRET trap  | dedicated decoder unit tests                 |
| 4 | `rvfi_order` strictly monotonic +1 per retirement across both channels combined (no gaps, no duplicates). When both channels retire in the same cycle, channel-0 order = N and channel-1 order = N+1.                                       | `riscv-formal unique` check                  |
| 5 | CPU makes forward progress under any symbolic instruction stream                                           | `riscv-formal liveness` check                |
| 5b | M-extension arithmetic produces RV32M-correct bit results                                                | cocotb `test_alu.py` + `make formal-deep`    |
| 6 | All memory accesses bounded to `[0x00000000, 0x00100000)` plus UART/markers `[0x10000000, 0x10000200)`     | sim emits `oob:true`, eval treats as failure |
| 7 | CoreMark CRCs match canonical 6 KB perf run: `crclist=0xd4b0`, `crcmatrix=0xbe52`, `crcstate=0x5e47`       | `validate_coremark_uart` in fpga eval        |
| 8 | CoreMark timing brackets `start_time` / `stop_time` markers — total elapsed cycles do NOT count            | MMIO writes at `0x10000100` / `0x10000104`   |
| 9 | "Correct operation validated." literal must appear in CoreMark UART output                                 | `validate_coremark_uart`                     |
|10 | Decoder defaults `isIllegal = 1`; a bit is only cleared inside a validated opcode/funct match              | decoder unit tests with reserved encodings   |

## Style rules (write these into every commit you author)

- **No `initial` blocks** in synthesizable code. Reset values come from a
  synchronous reset clause inside `always_ff`.
- **No latches.** Every `always_comb` covers all branches, every `case` has
  a `default`, every `if` has an `else`.
- **Pipeline regs are explicit `always_ff @(posedge clock) if (reset) … else …` blocks.**
  No clever defaults, no `assign` to next-state-of-a-register.
- **All RAM declarations carry `(* ram_style = "block" *)`** (and a Gowin
  equivalent in `synth.tcl`) so BRAM inference is deterministic.
- **Decoder defaults to `isIllegal = 1`.** A `case` arm clears it only after
  positively validating both opcode and funct fields.
- **Every module has a header comment** stating: purpose, latency
  (combinational vs N-cycle), and which RVFI fields it contributes to.
- **`logic`, never `reg` or `wire`.** SystemVerilog has unified the type.
- **No 2-state types (`bit`, `int`) in synthesizable code.** Use `logic`
  everywhere.
- **One module per file, named identically to the file** (lowercase).
- **`import core_pkg::*;` at the top of every RTL file** that uses shared
  types. No `\`include` for shared headers.

## Don't-touch list (the orchestrator never modifies these)

These directories are part of the eval contract and are *never* modified by
hypothesis-implementation agents. The hypothesis is "what RTL changes would
improve fitness", not "what eval relaxations would let this RTL pass".

- `tools/` — orchestrator, worktree manager, eval gates.
- `schemas/` — hypothesis and eval-result JSON schemas.
- `formal/wrapper.sv`, `formal/checks.cfg`, `formal/run_all.sh` — they
  define the correctness contract.
- `formal/riscv-formal/` — vendored upstream submodule.
- `bench/programs/` — selftest, crt0, link.ld, CoreMark sources, portme.
- `fpga/CoreBench.sv`, `fpga/scripts/*`, `fpga/constraints/*` — they define
  the FPGA fitness contract.
- `test/cosim/main.cpp`, `test/cosim/reference.py`, `test/cosim/run_cosim.py`
  — Verilator harness + Python ISS = the cosim contract.
- This file (`CLAUDE.md`), `ARCHITECTURE.md`, `README.md`, `setup.sh`,
  `Makefile`.

## What hypotheses MAY change

Everything under `rtl/` and the cocotb unit tests under `test/`.

The only top-level invariant on `rtl/core.sv` is that it exposes a port
named `core` whose IO matches the RVFI wrapper's expectations
(`io_imemAddr`, `io_imemData`, `io_imemReady`, `io_dmemAddr`, `io_dmemRData`,
`io_dmemWData`, `io_dmemWEn`, `io_dmemREn`, `io_dmemReady`, all
`io_rvfi_*_0` and `io_rvfi_*_1` fields, `clock`, `reset`).

A hypothesis may:
- Merge stages into a single file or split a module across many.
- Rename or delete files inside `rtl/`.
- Add new modules (branch predictors, caches, reservation stations…).
- Change pipeline depth (add or remove stages).
- Restructure the pipeline topology end to end.
- Rewrite any `rtl/` module from scratch.

It must not:
- Change `core`'s top-level IO shape — specifically: the imem/dmem port set, and the **2-channel** RVFI port set with field naming `io_rvfi_<field>_<n>` for n ∈ {0,1}, channel-0-older convention, and the single-retire-on-channel-0 rule.
- Weaken any invariant in the table above.
- Modify any path in the don't-touch list.

## Working notes

- This file is the contract. `docs/bootstrap-prompt.md` is the long-form
  plan that produced it.
- When in doubt about scope, prefer keeping a hypothesis minimal — a
  one-feature change is easier to explain and easier to revert if
  fitness regresses on the next iteration.

### Superscalar / NRET=2 contract

The RVFI port set is fixed at NRET=2 to permit dual-issue hypotheses
without contract churn. Single-issue cores tie channel 1 off
(`io_rvfi_valid_1 = 0` plus the rest of channel 1's fields driven to
`'0`) — about 21 lines of `assign io_rvfi_*_1 = '0;`. Triple-issue or
wider would be a future contract bump (NRET=K), not a per-hypothesis
decision.

The contract-side files that this widening touches: `rtl/core.sv`
(port set), `formal/wrapper.sv` (macro packing), `formal/checks.cfg`
(`nret 2`), `formal/run_all.sh` (vacuous-pass tally — see below),
`fpga/core_bench.sv` (bench wiring), `test/cosim/main.cpp`
(per-channel drain), and `test/test_pipeline.py` (cocotb probes use
`_0` suffix).

Vacuous-pass on channel 1: `riscv-formal`'s per-channel BMC checks
assume `rvfi_valid_<ch>=1` to test their property. When a single-issue
hypothesis hardwires `io_rvfi_valid_1 = 0`, that assumption becomes
unsatisfiable and SBY exits `Status: PREUNSAT` (rc=16) — technically a
vacuous pass over the empty set of ch1-valid traces. `formal/run_all.sh`
counts `*_ch1` PREUNSAT as pass, so single-issue hypotheses pass formal
naturally and dual-issue hypotheses (where ch1 is sometimes valid) get
the regular `DONE (PASS` outcome on the same checks. Caveat: a
hypothesis that *claims* dual-issue but whose channel 1 silently never
retires would also vacuous-pass these checks; the FPGA-fitness IPC and
the existing cover statement (which fires on either channel retiring)
catch the fully-stuck case.

## Caveat: `make formal` runs ALTOPS-mode by default

`formal/checks.cfg` defines `RISCV_FORMAL_ALTOPS`, which substitutes
the M-extension `MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU` operations
with simpler XOR-of-add/sub formulas (riscv-formal docs §7.6). The
DUT's `alu.sv` mirrors the same substitution under the same `\`ifdef`.

This means the per-iteration formal gate proves **M-ext bypassing,
operand routing, stall/forwarding behavior, and trap discipline** — but
it does NOT prove that the actual hardware multiplier and divider
produce RV32M-correct bit results. M-ext arithmetic correctness is
covered separately by:

  1. `test/test_alu.py` (30+ vectors per M-ext op, exact bit results)
  2. cosim against `test/cosim/reference.py` (each retired MUL/DIV/REM
     diff'd field-by-field with the Python ISS)
  3. `make formal-deep` (formal without ALTOPS — slow but the only path
     that proves real arithmetic via SMT). Run periodically, not in
     the orchestrator loop.

A hypothesis that touches the multiplier/divider must keep both the
ALTOPS branch and the real branch in `alu.sv` consistent. The cocotb
suite is the fast guard against arithmetic regressions.
