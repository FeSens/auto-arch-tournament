# Project Scope — Chisel → SystemVerilog Port

## Objective

Replace the Chisel-emitted RTL with hand-written SystemVerilog as the source
of truth for the CPU, while preserving every downstream tool (Verilator
cosim, riscv-formal, Yosys + nextpnr, CoreMark) and the AutoResearch
orchestration loop. After the port, the LLM agents iterate on `.sv` files
directly instead of `.scala`.

## Non-Goals

- No changes to the ISA (RV32IM, M-mode only, EBREAK as termination marker).
- No changes to the RVFI contract — every existing formal / cosim check must
  pass against the new RTL byte-identically (or with an explicitly justified
  diff).
- No new microarchitectural features (caches, branch predictors, multi-issue)
  introduced as part of the port itself. Those become hypotheses for the
  research loop *after* the SV baseline is green.
- No build system rewrite. Mill stays for compatibility, but `mill
  chisel.runMain core.Generate` is replaced by a no-op or a copy step.
- No SystemVerilog UVM. Tests use cocotb (Python) and direct Verilator
  testbenches, matching the project's existing simulation approach.

## What Stays Untouched

These directories and files are unaffected by the port:

- `bench/programs/` — selftest.S, crt0.S, link.ld, CoreMark sources, portme.c.
- `formal/riscv-formal/` — vendored riscv-formal repo.
- `formal/wrapper.sv`, `formal/checks.cfg`, `formal/run_all.sh` — the wrapper
  already drives `Core` by SV port names that the new RTL must keep.
- `fpga/CoreBench.sv`, `fpga/scripts/synth.tcl`,
  `fpga/scripts/nextpnr_run.sh`, `fpga/constraints/*` — they read the same
  `generated/Core.sv` (or its replacement at the same path).
- `chisel/test/cosim/main.cpp`, `reference.py`, `run_cosim.py`, `build.sh` —
  the Verilator harness binds to `Core` by SV port names.
- `tools/eval/cosim.py`, `tools/eval/formal.py`, `tools/eval/fpga.py`,
  `tools/orchestrator.py`, `tools/worktree.py`, `schemas/` — the eval
  pipeline is RTL-language-agnostic.

The single invariant the SV port must respect: produce a top-level module
named `Core` whose IO matches the current `generated/Core.sv` exactly
(`io_imemAddr`, `io_imemData`, `io_dmemAddr`, `io_dmemRData`, `io_dmemWData`,
`io_dmemWEn`, `io_dmemREn`, all `io_rvfi_*` fields, plus `clock` and
`reset`). The MEM_WB → RVFI semantics, including `rvfi_trap` driven from
`isIllegal`, must hold.

## Module Map (Chisel → SystemVerilog)

| Chisel source                         | New SystemVerilog file        | Notes                                                                                          |
| ------------------------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------- |
| `chisel/src/Core.scala`               | `rtl/core/core.sv`            | Top-level wiring, RVFI register, `rvfi_order` counter. Exposes the same `io_*` ports.          |
| `chisel/src/CoreConfig.scala`         | `rtl/core/core_pkg.sv`        | `package core_pkg`: AluOp/BranchOp constants, pipeline-bundle `typedef struct`s, `RVFIPort`.   |
| `chisel/src/IFStage.scala`            | `rtl/core/if_stage.sv`        | PC reg, redirect mux, bubble injection (NOP=0x13).                                             |
| `chisel/src/IDStage.scala`            | `rtl/core/id_stage.sv`        | Decoder + ImmGen instantiation, ID/EX register, stall/flush.                                   |
| `chisel/src/EXStage.scala`            | `rtl/core/ex_stage.sv`        | ALU, branch resolve, redirect target, EX/MEM register, forwarding muxes.                       |
| `chisel/src/MEMStage.scala`           | `rtl/core/mem_stage.sv`       | Byte-lane mask + replicate, sign-/zero-extend load, MEM/WB register.                           |
| `chisel/src/WBStage.scala`            | `rtl/core/wb_stage.sv`        | Reg-file write mux. Trivial.                                                                   |
| `chisel/src/HazardUnit.scala`         | `rtl/core/hazard_unit.sv`     | Load-use detect, stall/flush outputs.                                                          |
| `chisel/src/ForwardUnit.scala`        | `rtl/core/forward_unit.sv`    | Two 2-bit selects driven from EX/MEM and MEM/WB rd.                                            |
| `chisel/src/util/ALU.scala`           | `rtl/core/alu.sv`             | RV32IM ALU. Hardware `*` and `/` are SystemVerilog `signed` operators.                         |
| `chisel/src/util/Decoder.scala`       | `rtl/core/decoder.sv`         | Default `isIllegal=1`, cleared per validated opcode/funct match. Largest single port effort.   |
| `chisel/src/util/ImmGen.scala`        | `rtl/core/imm_gen.sv`         | I/S/B/U/J immediate sign-extension.                                                            |
| `chisel/src/util/RegFile.scala`       | `rtl/core/reg_file.sv`        | 32×32, x0 hardwired, write-first bypass.                                                       |
| `chisel/src/SoC.scala`                | `rtl/core/soc.sv`             | imem/dmem (`logic [31:0] mem [0:8191]`), 9600-baud UART. Single `uart_tx` output.              |
| `chisel/src/Generate.scala`           | *(deleted)*                   | No more Chisel emission step.                                                                  |
| `chisel/src/GenerateSoC.scala`        | *(deleted)*                   | Same.                                                                                          |

The `package core_pkg` is the most important shared file: every `*.sv`
imports it with `import core_pkg::*;` for AluOp/BranchOp/Bundle types. It
must stay enum/struct-based (not bit-fields) so Verilator and Yosys both
accept it cleanly.

## Build Flow Changes

| Step                          | Before                                                          | After                                                                                  |
| ----------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Source of truth               | `chisel/src/*.scala`                                            | `rtl/core/*.sv`                                                                        |
| Verilog emit                  | `mill chisel.runMain core.Generate --target-dir generated`      | `cp rtl/core/*.sv generated/` (or run a tiny `tools/build_rtl.sh` that concatenates).  |
| `make verilog`                | calls Generate + GenerateSoC                                    | shell copy + `iverilog -g2012 -t null` syntax check                                    |
| `make compile`                | `mill chisel.compile`                                           | (deleted) — no Scala build                                                             |
| `make test`                   | `mill chisel.test`                                              | `cocotb-config make` for unit tests; `verilator --binary -DUNIT_TEST` for SV TBs       |
| `chisel/test/cosim/build.sh`  | reads `generated/Core.sv`                                       | unchanged                                                                              |
| `formal/run_all.sh`           | reads `generated/Core.sv`                                       | unchanged                                                                              |
| `fpga/scripts/synth.tcl`      | reads `generated/Core.sv` via `fpga/CoreBench.sv` `\`include`   | unchanged                                                                              |
| `tools/orchestrator.py`       | calls `mill chisel.runMain` and `mill chisel.compile` checks    | calls `tools/build_rtl.sh`; preserves the worktree → eval flow byte-for-byte           |

`Makefile` and `tools/orchestrator.py:emit_verilog` are the only orchestration
points that need to change. Both have a single mill invocation today.

## Test Strategy

The Chisel side has 61 unit tests across 5 spec files. The port replaces them
as follows:

| Chisel spec                          | Replacement                                                                                              |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `ALUSpec.scala` (25 tests)           | `rtl/test/cocotb/test_alu.py` — drives `alu.sv` with the same input vectors, same expected values.       |
| `DecoderSpec.scala` (26 tests)       | `rtl/test/cocotb/test_decoder.py` — combinational poke-and-check, including isIllegal coverage.          |
| `ImmGenSpec.scala`                   | `rtl/test/cocotb/test_imm_gen.py`.                                                                       |
| `RegFileSpec.scala`                  | `rtl/test/cocotb/test_reg_file.py` — write-first bypass test included.                                   |
| `PipelineSpec.scala` (10 tests)      | `rtl/test/cocotb/test_pipeline.py` — full Core wrapper with scratch dmem, all forwarding/branch/trap.    |

Cocotb is preferred over a pure-SV testbench because (a) it shares Python
with the rest of the toolchain, (b) it produces structured JSON output the
orchestrator can grep, and (c) ChiselTest's `peek/poke/expect` style
translates to cocotb almost line-for-line.

A flat `pytest` runner (`make test` → `pytest rtl/test/cocotb/`) gives the
same single-command UX as `mill chisel.test`.

## Verification Plan

The port is considered correct when, against an identical bench/program ELF
set:

1. **All cocotb unit tests pass** (1:1 parity with the 61 Chisel tests).
2. **`run_cosim.py` selftest.elf**: same 58-retirement match between Verilator
   sim and the Python reference ISS.
3. **`run_cosim.py` coremark.elf**: CRC values match canonical (`crclist =
   0xd4b0`, `crcmatrix = 0xbe52`, `crcstate = 0x5e47`, `crcfinal = 0x273b`,
   `Correct operation validated` banner).
4. **`formal/run_all.sh`**: every check in `checks.cfg` passes. The depth
   config (insn=20, reg/pc/causal/unique/liveness=10/20, cover=1/20, ill=20)
   is unchanged.
5. **`tools.eval.fpga`**: produces a non-zero `fitness` with all three nextpnr
   seeds reaching place-and-route, OOB flag clear, and bench-bracketed cycle
   count present in the marker.

A regression is "anything that passed against the Chisel baseline now fails."
The baseline is locked in `experiments/log.jsonl` — the first improvement
entry's `fitness`, `lut4`, and `ff` are the comparison point.

## Phases

**Phase 0 — Decoder + ALU + ImmGen (combinational core)**
- Port `decoder.sv`, `alu.sv`, `imm_gen.sv`, `core_pkg.sv`.
- Bring up `test_alu.py`, `test_decoder.py`, `test_imm_gen.py` in cocotb.
- Acceptance: 51 of 61 unit tests pass (the combinational ones).

**Phase 1 — Reg file + Pipeline regs**
- Port `reg_file.sv`, all five `*_stage.sv`, `hazard_unit.sv`,
  `forward_unit.sv`.
- Bring up `test_reg_file.py` and a minimal `test_pipeline.py` (the
  4-instruction baseline).
- Acceptance: all 61 unit tests pass.

**Phase 2 — Top-level Core + cosim parity**
- Port `core.sv` with full RVFI wiring, `rvfi_order` register,
  `trap = isIllegal` route.
- Drop the new `core.sv` into `generated/` (or wire `make verilog` to copy
  from `rtl/core/`). Rebuild Verilator cosim binary.
- Run `run_cosim.py` against selftest.elf. Diff trace against the previous
  Chisel build's trace — expect bit-identical retirements (same `order`,
  `pc`, `insn`, `rd_addr`, `rd_wdata`, `mem_*`).
- Acceptance: selftest cosim passes; cycle count within ±1 cycle of the
  Chisel baseline (one-cycle difference is acceptable for reset-pipeline
  latency variation, anything larger is a real divergence).

**Phase 3 — Formal parity**
- Run `formal/run_all.sh`. Every check that passed on the Chisel baseline
  must pass on the SV port.
- Acceptance: pass count and pass list identical to the locked baseline.

**Phase 4 — SoC + FPGA fitness**
- Port `soc.sv` (imem/dmem `logic [31:0] mem[0:8191]`, UART FSM at
  `0x10000000`).
- Run `tools.eval.fpga`. Compare median Fmax, LUT4, FF, fitness to baseline.
- Acceptance: Fmax within 5% of baseline (synthesis is non-deterministic
  across hand-written vs Chisel-emitted RTL; a small drift is expected). LUT4
  count within 10%. CoreMark CRC and bench-bracketed cycle count must match
  the Chisel baseline exactly.

**Phase 5 — Toolchain cleanup**
- Delete `chisel/` subtree (or move it to `legacy/chisel/`).
- Strip Mill from `Makefile` and `setup.sh`. Adjust `tools/orchestrator.py`
  to drop `mill chisel.runMain`.
- Update `ARCHITECTURE.md` and `CLAUDE.md` to point at `rtl/`.
- Acceptance: `make next` runs the full pipeline without invoking Mill or
  Scala.

## Acceptance Criteria (overall)

The port is done when *every* one of these is true on a clean checkout:

- [ ] `make test` → all 61 cocotb tests pass
- [ ] `make cosim-build && python3 chisel/test/cosim/run_cosim.py …
      bench/programs/selftest.elf` → `{"passed": true, "retired": 58}`
- [ ] `python3 -m tools.eval.cosim .` → CoreMark CRC validated
- [ ] `make formal` → `Formal: N passed, 0 failed` (N matches baseline)
- [ ] `python3 -m tools.eval.fpga .` → `fitness > 0`, `oob` clear,
      `bench_bracketed: true`
- [ ] `make next` runs end-to-end without Mill / Scala / firtool

## Risks

- **Decoder regression risk.** The Chisel decoder has subtle defaults (e.g.
  `isIllegal := true.B` only cleared inside validated `when` blocks). Hand-SV
  with `case` + default branches is easy to get wrong; a missed default lets
  reserved encodings retire silently. Mitigation: every reserved-encoding
  test in `DecoderSpec` ports verbatim to cocotb and must pass before Phase 0
  closes.

- **Pipeline timing drift.** Hand-SV register placement may differ from
  Chisel's emitted form by one inferred latch or mux level. RVFI traces would
  match but Fmax could swing ±10%. Mitigation: keep the pipeline regs as
  explicit `always_ff @(posedge clock)` blocks with named structs; avoid
  initial blocks that depend on synth-tool ordering.

- **`logic [N-1:0] mem [0:M-1]` inference variance.** Chisel's emitted Mem
  produces a specific port shape (1W, 2R for SoC's dmem). Yosys's inference
  for `synth_gowin` may pick BRAM, distributed, or split — each has
  different Fmax. Mitigation: explicit `(* ram_style = "block" *)` (or its
  Gowin equivalent) attribute on the `mem` declaration.

- **RVFI semantics drift on EBREAK / illegal.** The Chisel core treats EBREAK
  as a non-trapping retirement (rvfi.trap=0) and other 0x73 as illegal
  (rvfi.trap=1). The spec actually says EBREAK should trap; the test harness
  relies on the project's convention. The SV port must replicate this exact
  convention or every formal `insn_ebreak_check` will diverge. Document it
  explicitly in `decoder.sv`.

- **Build-flow assumption breakage.** `tools/orchestrator.py:emit_verilog`
  hardcodes `mill chisel.runMain core.Generate` and similar for SoC. The
  worktree-based eval expects `generated/Core.sv` and `generated/SoC.sv` to
  appear after that step. Mitigation: replace the mill calls with a script
  that produces the same artifacts at the same paths; otherwise every
  hypothesis worktree starts from a stale `generated/`.

## Open Questions

1. **Cocotb vs. SystemVerilog testbench.** Cocotb makes the eval harness
   uniform (Python everywhere) but adds a runtime dependency. A pure-SV TB
   keeps the tooling self-contained but duplicates assertions in two
   languages. *Recommendation: cocotb, because Python's set/dict semantics
   make trace diffing trivial and the orchestrator already requires Python.*

2. **Single-file vs per-module SV.** Chisel emits one big `Core.sv`; hand-SV
   could match that or split per-module. *Recommendation: per-module under
   `rtl/core/`, then concatenate (or use `\`include`) into `generated/Core.sv`
   for tools that want the flat file.*

3. **Type aliases vs raw bits.** `package core_pkg` can use `enum logic
   [4:0]` for AluOp or just `localparam`s. Yosys supports both; some legacy
   tools (older sby flows) prefer params. *Recommendation: `localparam`s for
   tool compatibility; struct typedefs for pipeline bundles.*

4. **Where to put hand-SV style guidelines.** ARCHITECTURE.md currently
   describes the Chisel layout. Should the SV port reuse it or get a sibling
   `rtl/STYLE.md`? *Recommendation: rewrite ARCHITECTURE.md once Phase 5
   closes; until then, a phase-local note in `rtl/README.md`.*
