# CLAUDE.md — non-negotiable invariants and don't-touch list

Every item below was a real bug in the prior Chisel iteration. Each must be
enforced by a check that fails loudly when violated. **Do not weaken these
checks** to make a hypothesis pass.

## Hard invariants

| # | Invariant                                                                                                  | Enforced by                                  |
|---|------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| 1 | Top module `core` exposes an RVFI port set selected by `cores/<target>/core.yaml`'s `nret` field (default 2). **nret=1**: only `io_rvfi_*_0` ports exist; the single retirement always lands on channel 0. **nret=2**: both `io_rvfi_*_0` and `io_rvfi_*_1` exist; channel 0 carries the older of two simultaneous retirements, channel 1 the younger; single-retire cycles MUST place the retirement on channel 0 with `io_rvfi_valid_1 = 0`; all channel-1 ports MUST be driven (no X/Z, tie unused fields to `'0`). | cocotb smoke test, `riscv-formal` wrapper (`wrapper.sv` for nret=2, `wrapper_si.sv` for nret=1) |
| 2 | `rvfi_trap = 1` iff the retiring instruction is illegal per RV32IM (decoder default = illegal)             | `riscv-formal ill` check                     |
| 3 | EBREAK is the *only* SYSTEM (opcode `0x73`) instruction the core treats as valid; ECALL / CSR / MRET trap  | dedicated decoder unit tests                 |
| 4 | `rvfi_order` strictly monotonic +1 per retirement across both channels combined (no gaps, no duplicates). When both channels retire in the same cycle, channel-0 order = N and channel-1 order = N+1.                                       | `riscv-formal unique` check                  |
| 5 | CPU makes forward progress under any symbolic instruction stream                                           | `riscv-formal liveness` check                |
| 5b | M-extension arithmetic produces RV32M-correct bit results                                                | cocotb `test_alu.py` + `make formal-deep`    |
| 6 | All memory accesses bounded to `[0x00000000, 0x00100000)` plus UART/markers `[0x10000000, 0x10000200)`     | sim emits `oob:true`, eval treats as failure |
| 7 | CoreMark CRCs match the canonical 2K-config perf run (`TOTAL_DATA_SIZE=2000`, `-O3`, `ITERATIONS=10`): `seedcrc=0xe9f5`, `crclist=0xe714`, `crcmatrix=0x1fd7`, `crcstate=0x8e3a`, `crcfinal=0xfcaf` | `validate_coremark_uart` in fpga eval (`COREMARK_EXPECTED` in `tools/eval/fpga.py` is the source of truth) |
| 8 | CoreMark timing brackets `start_time` / `stop_time` markers — total elapsed cycles do NOT count            | MMIO writes at `0x10000100` / `0x10000104`   |
| 9 | "Correct operation validated." literal must appear in CoreMark UART output                                 | `validate_coremark_uart`                     |
|10 | Decoder defaults `isIllegal = 1`; a bit is only cleared inside a validated opcode/funct match              | decoder unit tests with reserved encodings   |

## Don't-touch list (the orchestrator never modifies these)

These directories are part of the eval contract and are *never* modified by
hypothesis-implementation agents. The hypothesis is "what RTL changes would
improve fitness", not "what eval relaxations would let this RTL pass".

- `tools/` — orchestrator, worktree manager, eval gates.
- `schemas/` — hypothesis and eval-result JSON schemas.
- `formal/wrapper.sv`, `formal/wrapper_si.sv`, `formal/checks.cfg`,
  `formal/checks_si.cfg`, `formal/checks-deep.cfg`, `formal/run_all.sh`
  — they define the correctness contract (dual-channel + single-issue
  variants).
- `formal/riscv-formal/` — vendored upstream submodule.
- `bench/programs/` — selftest, crt0, link.ld, CoreMark sources, portme.
- `bench/holdout/` — held-out generalization benchmarks (stripped from
  bench fixtures).
- `fpga/core_bench.sv`, `fpga/core_bench_si.sv`, `fpga/scripts/*`,
  `fpga/constraints/*` — they define the FPGA fitness contract
  (dual-channel + single-issue variants).
- `test/cosim/main.cpp`, `test/cosim/reference.py`, `test/cosim/run_cosim.py`
  — Verilator harness + Python ISS = the cosim contract.
- This file (`CLAUDE.md`), `ARCHITECTURE.md`, `README.md`, `setup.sh`,
  `Makefile`.

## What hypotheses MAY change

Everything under `cores/<TARGET>/rtl/` and the cocotb unit tests under
`cores/<TARGET>/test/test_*.py`. The agent's `implementation_notes.md`
lives at `cores/<TARGET>/implementation_notes.md` (gitignored). The
orchestrator may also update `cores/<TARGET>/core.yaml` (current:
section only).

The only top-level invariant on `rtl/core.sv` is that it exposes a port
named `core` whose IO matches the RVFI wrapper's expectations: the
imem/dmem port set (`io_imemAddr`, `io_imemData`, `io_imemReady`,
`io_dmemAddr`, `io_dmemRData`, `io_dmemWData`, `io_dmemWEn`,
`io_dmemREn`, `io_dmemReady`), `clock`, `reset`, and the RVFI port
set determined by `core.yaml`'s `nret` field — only `io_rvfi_*_0`
fields for `nret: 1`; both `io_rvfi_*_0` and `io_rvfi_*_1` for
`nret: 2` (default).

A hypothesis may:
- Merge stages into a single file or split a module across many.
- Rename or delete files inside `rtl/`.
- Add new modules (branch predictors, caches, reservation stations…).
- Change pipeline depth (add or remove stages).
- Restructure the pipeline topology end to end.
- Rewrite any `rtl/` module from scratch.

It must not:
- Change `core`'s top-level IO shape relative to the `nret` value declared in `core.yaml` — specifically: the imem/dmem port set, and the RVFI port set (only `_0` fields for `nret: 1`; both `_0` and `_1` for `nret: 2` with channel-0-older convention and the single-retire-on-channel-0 rule).
- Change `core.yaml`'s `nret` value mid-hypothesis. nret picks the formal/FPGA wrappers used by eval; flipping it is a contract-level change, not a per-hypothesis decision.
- Weaken any invariant in the table above.
- Modify any path in the don't-touch list.
- Edit any other core's directory (cores/<other>/...). Each loop is
  scoped to a single TARGET.

## Working notes

This file is the contract. `docs/bootstrap-prompt.md` is the long-form
plan that produced it.

### RVFI contract: nret=1 vs nret=2

Cores declare their retirement width in `cores/<TARGET>/core.yaml`
under the top-level `nret` field. Two values are supported; the
default is 2 for backward compat with cores authored before this
field existed.

- `nret: 1` — single-issue. Top module exposes only `io_rvfi_*_0`
  ports (no `_1`). Orchestrator wires `formal/wrapper_si.sv` +
  `formal/checks_si.cfg` for formal and `fpga/core_bench_si.sv` for
  FPGA Fmax. No `_1` tie-offs to write; no vacuous-pass machinery
  involved. This is the recommended shape for any in-order or
  single-retire pipeline.
- `nret: 2` — dual-issue (or single-issue cores that opt into the
  wider contract). Top module exposes both `io_rvfi_*_0` and
  `io_rvfi_*_1` with the channel-0-older convention.
  `formal/wrapper.sv` + `formal/checks.cfg` and `fpga/core_bench.sv`
  apply. Single-issue cores declared as `nret: 2` must still tie off
  channel 1 (`io_rvfi_valid_1 = 0` plus all other `_1` fields driven
  to `'0`) — about 21 `assign io_rvfi_*_1 = '0;` lines.

Triple-issue or wider would be a future contract bump (NRET=K), not a
per-hypothesis decision.

Contract-side files keyed off `nret`:
- nret=1: `formal/wrapper_si.sv`, `formal/checks_si.cfg`,
  `fpga/core_bench_si.sv`.
- nret=2: `formal/wrapper.sv`, `formal/checks.cfg`,
  `fpga/core_bench.sv`.
- shared: `formal/run_all.sh`, `fpga/scripts/synth.tcl`,
  `test/cosim/main.cpp` (per-channel drain that gracefully no-ops
  on unused channels).

Vacuous-pass on channel 1 (`nret: 2` only): `riscv-formal`'s
per-channel BMC checks assume `rvfi_valid_<ch>=1` to test their
property. When a single-issue hypothesis declared as `nret: 2`
hardwires `io_rvfi_valid_1 = 0`, that assumption becomes
unsatisfiable and SBY exits `Status: PREUNSAT` (rc=16) — technically
a vacuous pass over the empty set of ch1-valid traces.
`formal/run_all.sh` counts `*_ch1` PREUNSAT as pass, so such
hypotheses pass formal naturally and true dual-issue hypotheses
(where ch1 is sometimes valid) get the regular `DONE (PASS` outcome
on the same checks. Caveat: a hypothesis that *claims* dual-issue
but whose channel 1 silently never retires would also vacuous-pass
these checks; the FPGA-fitness IPC and the cover statement (which
fires on either channel retiring) catch the fully-stuck case.
Cores declared `nret: 1` sidestep this machinery entirely —
checks_si.cfg generates no `_ch1` tasks at all.

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

  1. `cores/<TARGET>/test/test_alu.py` (30+ vectors per M-ext op, exact bit results)
  2. cosim against `test/cosim/reference.py` (each retired MUL/DIV/REM
     diff'd field-by-field with the Python ISS)
  3. `make formal-deep` (formal without ALTOPS — slow but the only path
     that proves real arithmetic via SMT). Run periodically, not in
     the orchestrator loop.

A hypothesis that touches the multiplier/divider must keep both the
ALTOPS branch and the real branch in `alu.sv` consistent. The cocotb
suite is the fast guard against arithmetic regressions.
