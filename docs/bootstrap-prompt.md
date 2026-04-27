# Bootstrap Plan — RISC-V Auto-Architecture (SystemVerilog Edition)

> Self-contained plan + agent prompt to spin up a *new* repo where
> SystemVerilog is the source of truth. No Chisel, no firtool, no Mill.
> Lessons from the prior Chisel-based project are baked into the
> non-negotiable invariants below.

---

## 1. Mission

Build an LLM-driven research environment where an agent loop iteratively
proposes microarchitectural hypotheses on a 5-stage in-order RV32IM core
written in SystemVerilog, and a deterministic eval pipeline grades each
hypothesis on:

1. **Correctness** — riscv-formal + Verilator cosim against a Python ISS
2. **Performance** — CoreMark iter/sec on a Gowin GW2A FPGA target

The orchestrator accepts improvements (higher iter/sec) and rejects
regressions or broken hypotheses, building a chain of verifiably-correct
performance wins over time.

## 2. Why Not Just Port the Old Repo

Lessons from the Chisel iteration that demand a fresh start:

- The Chisel emit step (Mill → CIRCT firtool → SV) is a 30-second tax on
  every iteration and a permanent maintenance burden. Pure SV cuts it.
- A full audit found 15 verification bugs in the old harness — fake-pass
  paths, silent OOB wraparound, missing `ill`/`unique`/`liveness`/`cover`
  formal checks, raw-cycle CoreMark scoring, illegal-instruction silent NOPs.
  Each one is a precondition this scope makes explicit so the new repo
  starts correct.
- The decoder's `MuxLookup(default=ADD)` pattern silently mapped reserved
  encodings to ADD. Hand-SV with explicit `default: illegal = 1'b1` gets
  this right by construction.
- BRAM inference (Yosys + Mem→BRAM) is non-deterministic across Chisel
  versions. Hand-SV with explicit `(* ram_style *)` attributes is reliable.

## 3. Hard Invariants (test these on day one)

These are non-negotiable. Every one of them was a bug in the prior repo;
each must be enforced by a check that fails loudly if violated.

| # | Invariant                                                                                                  | Enforced by                                  |
|---|------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| 1 | Top module `core` exposes the RVFI port set (32 signals, exact names)                                      | `cocotb` smoke test, `riscv-formal` wrapper  |
| 2 | `rvfi_trap = 1` iff the retiring instruction is illegal per RV32IM (decoder default = illegal)             | `riscv-formal ill` check                     |
| 3 | EBREAK is the *only* SYSTEM (opcode 0x73) instruction the core treats as valid; ECALL/CSR/MRET trap        | dedicated decoder unit tests                 |
| 4 | `rvfi_order` strictly monotonic +1 per retirement (no double-retire)                                       | `riscv-formal unique` check                  |
| 5 | CPU makes forward progress under any symbolic instruction stream                                           | `riscv-formal liveness` check                |
| 6 | All memory accesses bounded to <1 MiB except UART range 0x1000_0000 / bench markers 0x1000_0100/0x1000_0104 | sim emits `oob:true`, eval treats as failure |
| 7 | CoreMark CRCs match canonical 6K perf run: `crclist=0xd4b0`, `crcmatrix=0xbe52`, `crcstate=0x5e47`         | `validate_coremark_uart` in fpga eval        |
| 8 | CoreMark timing brackets `start_time/stop_time` — total elapsed cycles do NOT count                        | MMIO marker writes 0x1000_0100/0x1000_0104   |
| 9 | "Correct operation validated." literal must appear in CoreMark UART output                                  | `validate_coremark_uart`                     |
| 10| The decoder defaults `isIllegal = 1`; a bit is only cleared inside a validated opcode/funct match          | `decoder` unit tests with reserved encodings |

## 4. Architecture (target microarchitecture, version 1)

A textbook 5-stage in-order pipeline. **No** caches, **no** branch predictor,
**no** out-of-order. Those are research-loop hypotheses for later, not
day-one features.

```
   ┌────┐  ┌────┐  ┌────┐  ┌─────┐  ┌────┐
   │ IF │→│ ID │→│ EX │→│ MEM │→│ WB │
   └────┘  └────┘  └────┘  └─────┘  └────┘
      │       │       ▲
      │       └───────┤    (forward EX→ID, MEM→ID)
      │               │
      └─── stall ←────┘    (load-use hazard)
```

- **IF**: PC reg, +4 by default, redirected by EX on taken branch / JAL / JALR.
  Bubble injection (NOP = 0x00000013) on flush.
- **ID**: Decoder + ImmGen, regfile read, ID/EX latch.
- **EX**: ALU (RV32IM, hardware multiplier, div-by-0 + INT_MIN/-1 spec
  cases), branch resolve, redirect target, EX/MEM latch. Forwarding muxes
  for rs1/rs2 (EX→EX, MEM→EX).
- **MEM**: byte-lane mask + replicated wdata, sign/zero-extended load,
  word-aligned mem_addr for RVFI ALIGNED_MEM. MEM/WB latch.
- **WB**: regfile write mux (alu vs loaded data).
- **Hazard unit**: load-use stall (1 cycle).
- **Forward unit**: 2-bit selects from EX/MEM rd and MEM/WB rd.
- **Reg file**: 32×32, x0 hardwired, write-first bypass.

RVFI port lives at top-level only. Stages do not see RVFI; the MEM/WB
register has every field needed and the top wires them through.

## 5. Repo Layout

```
.
├── README.md                  # quickstart + status badges
├── ARCHITECTURE.md            # the section-4 microarchitecture spec
├── CLAUDE.md                  # invariants + don't-touch list (this file's §3)
├── Makefile                   # entry points: lint, test, cosim, formal, fpga, next
├── setup.sh                   # one-shot toolchain installer (Verilator, OSS CAD Suite, riscv32-elf-gcc, cocotb)
│
├── rtl/
│   ├── core_pkg.sv            # AluOp/BranchOp localparams, pipeline struct typedefs
│   ├── core.sv                # top-level wiring + RVFI register
│   ├── if_stage.sv
│   ├── id_stage.sv
│   ├── ex_stage.sv
│   ├── mem_stage.sv
│   ├── wb_stage.sv
│   ├── alu.sv
│   ├── decoder.sv
│   ├── imm_gen.sv
│   ├── reg_file.sv
│   ├── hazard_unit.sv
│   ├── forward_unit.sv
│   └── soc.sv                 # imem/dmem (8K×32 each), 9600-baud UART
│
├── test/
│   ├── conftest.py            # cocotb fixtures
│   ├── test_alu.py            # ≥30 ALU vectors incl. div-by-0, INT_MIN/-1, MULHSU
│   ├── test_decoder.py        # ≥40 cases incl. reserved funct3/funct7 / ECALL / MRET / unknown ops
│   ├── test_imm_gen.py
│   ├── test_reg_file.py
│   ├── test_hazard_unit.py
│   ├── test_forward_unit.py
│   ├── test_pipeline.py       # forwarding, branches, JAL, SW+LW, load-use, illegal trap
│   └── cosim/
│       ├── main.cpp           # Verilator harness with OOB detection + bench markers
│       ├── reference.py       # Python RV32IM ISS (golden model)
│       ├── run_cosim.py       # diffs RVFI traces field-by-field
│       └── build.sh
│
├── bench/
│   └── programs/
│       ├── selftest.S         # exercises ALU, sub-word load/store, branches, JAL
│       ├── crt0.S
│       ├── link.ld
│       ├── Makefile
│       └── coremark/          # vendored EEMBC CoreMark + baremetal portme.c
│
├── formal/
│   ├── checks.cfg             # insn / reg / pc_fwd / pc_bwd / causal / unique / cover / ill / liveness
│   ├── wrapper.sv             # symbolic imem, 8 KiB dmem, RVFI bind
│   ├── run_all.sh
│   └── riscv-formal/          # git submodule
│
├── fpga/
│   ├── core_bench.sv          # LFSR-driven imem + 8K-word dmem; XOR-reduce LED to retain logic
│   ├── constraints/
│   │   └── tang_nano_20k.cst
│   └── scripts/
│       ├── synth.tcl
│       └── nextpnr_run.sh
│
├── tools/
│   ├── orchestrator.py        # hypothesize → implement → eval loop
│   ├── worktree.py            # git worktree per hypothesis
│   ├── plot.py                # progress chart
│   └── eval/
│       ├── cosim.py           # selftest full-trace + coremark CRC
│       ├── formal.py          # parses run_all.sh output
│       └── fpga.py            # 3-seed nextpnr median Fmax + bracketed CoreMark cycles
│
├── schemas/
│   ├── hypothesis.schema.json
│   └── eval_result.schema.json
│
└── experiments/
    ├── log.jsonl              # append-only (one entry per iteration)
    ├── hypotheses/            # generated hypothesis YAMLs
    └── worktrees/             # per-hypothesis git worktrees
```

## 6. Tech Stack

| Concern             | Tool / Version                                                  |
|---------------------|-----------------------------------------------------------------|
| RTL                 | SystemVerilog (IEEE 1800-2017 synthesizable subset)             |
| Sim                 | Verilator ≥ 5.0                                                 |
| Unit tests          | cocotb ≥ 1.8 (Python harness; runs under Verilator)             |
| Formal              | YosysHQ riscv-formal (vendored as submodule); sby + bitwuzla    |
| Synth               | Yosys + `synth_gowin`                                           |
| Place & route       | nextpnr-himbaechel (Gowin GW2A-LV18QN88C8/I7 = Tang Nano 20K)   |
| Cross-compiler      | xPack riscv-none-elf-gcc 15.x (symlinked to riscv32-unknown-elf)|
| Orchestrator        | Python 3.11+, jsonschema, pyyaml, matplotlib                    |
| OSS CAD Suite       | Latest (bundles yosys, nextpnr, sby, bitwuzla, smtbmc)          |

`setup.sh` mirrors the prior repo's installer for Verilator / OSS CAD Suite /
xPack toolchain — that part can be lifted nearly verbatim. The Mill /
firtool / Chisel branches all delete.

## 7. Eval Pipeline (the gates a hypothesis must pass)

In order, with short-circuit on first failure:

1. **Lint** — `verilator --lint-only -Wall rtl/*.sv` must be clean.
2. **Unit tests** — `pytest test/` (all cocotb tests pass).
3. **Cosim** — `python3 -m tools.eval.cosim .`
   - selftest.elf: full RVFI trace match between sim and Python ISS
     (every field including `rs1_addr`, `rs2_addr`, `mem_addr`, `mem_rmask`,
     `mem_wmask`, `mem_rdata`, `mem_wdata`, `trap`, `halt`, `intr`, `mode`,
     `ixl`).
   - coremark.elf: CRC validated via UART output (no full-trace cosim
     because the Python ISS is too slow).
4. **Formal** — `bash formal/run_all.sh` — every check in `checks.cfg`
   passes (≈53 checks: 45 insn_*, plus reg, pc_fwd, pc_bwd, causal, unique,
   cover, ill, liveness).
5. **FPGA** — `python3 -m tools.eval.fpga .`
   - Synthesize `core_bench.sv` with Yosys (`synth_gowin`).
   - 3 nextpnr seeds in parallel; median Fmax wins.
   - Run CoreMark on Verilator with `--bench` mode; require
     `bench_bracketed=true` and OOB clear; compute
     `iter_per_cycle = 100 / (bench_stop_cycle − bench_start_cycle)`.
   - `fitness = fmax_median_mhz × iter_per_cycle × 1e6` (iter/sec).

The fitness number is the only quantity the orchestrator optimizes.
Everything before it is a binary gate — pass or broken.

## 8. Phases

**Phase 0 — Repo skeleton + toolchain (1 day)**
- `setup.sh` installs Verilator, OSS CAD Suite, riscv32-elf-gcc, cocotb.
- Empty `Makefile` with `lint`, `test`, `cosim`, `formal`, `fpga`, `next`,
  `report` targets that all `echo "TODO"`.
- README with the quickstart commands.
- *Acceptance:* `bash setup.sh` exits 0; `make lint` runs verilator on the
  (empty) `rtl/` and prints "no files".

**Phase 1 — Combinational core (2 days)**
- `core_pkg.sv`, `decoder.sv`, `alu.sv`, `imm_gen.sv`, `reg_file.sv`.
- Cocotb tests for each. Decoder tests must include every reserved-funct
  encoding listed in §3 invariant 10.
- *Acceptance:* `make test` passes; verilator lint clean.

**Phase 2 — Pipeline + Core top (3 days)**
- `if_stage.sv`, `id_stage.sv`, `ex_stage.sv`, `mem_stage.sv`,
  `wb_stage.sv`, `hazard_unit.sv`, `forward_unit.sv`, `core.sv`.
- `test_pipeline.py` covering forwarding, branches, JAL, SW+LW roundtrip,
  load-use stall, illegal trap, ECALL trap, EBREAK does NOT trap.
- *Acceptance:* all unit tests pass.

**Phase 3 — Cosim (2 days)**
- `test/cosim/main.cpp` with OOB detection and `--bench` mode emitting
  `bench_start_cycle` / `bench_stop_cycle` markers.
- `test/cosim/reference.py` (Python RV32IM ISS, ≤500 LOC).
- `test/cosim/run_cosim.py` diffs every RVFI field.
- selftest.elf + crt0.S + link.ld; matches the prior repo verbatim.
- *Acceptance:* `python3 test/cosim/run_cosim.py … selftest.elf` →
  `{"passed": true, "retired": 58}`.

**Phase 4 — Formal (2 days)**
- Vendor riscv-formal as submodule; write `formal/wrapper.sv` and
  `formal/checks.cfg` with the full check set (§7 step 4).
- *Acceptance:* `bash formal/run_all.sh` → "Formal: 53 passed, 0 failed"
  (counts may vary slightly with isa string).

**Phase 5 — Bench programs + CoreMark (2 days)**
- Vendor EEMBC CoreMark; write `core_portme.c` with UART at 0x1000_0000
  and bench markers at 0x1000_0100/0x1000_0104.
- `bench/programs/Makefile` builds selftest.elf + coremark.elf.
- *Acceptance:* CoreMark on Verilator (with `--bench`) emits
  `crclist=0xd4b0`, `crcmatrix=0xbe52`, `crcstate=0x5e47`,
  `crcfinal=0x273b`, "Correct operation validated."

**Phase 6 — FPGA fitness (2 days)**
- `fpga/core_bench.sv` with LFSR imem + 8K-word dmem + XOR-reduce LED.
- `fpga/scripts/synth.tcl` + `nextpnr_run.sh`.
- `tools/eval/fpga.py` — 3-seed median Fmax + bracketed CoreMark cycles.
- *Acceptance:* `python3 -m tools.eval.fpga .` returns a non-zero
  `fitness`, `oob: false`, `bench_bracketed: true`.

**Phase 7 — Orchestrator (3 days)**
- Hypothesis schema, eval-result schema.
- `tools/orchestrator.py`: hypothesis agent → implement agent → eval gates.
- Worktree-per-hypothesis with `git worktree`.
- *Acceptance:* `make next` runs one full iteration and appends to
  `experiments/log.jsonl` with either `outcome: improvement` (rare on first
  run), `outcome: regression`, or `outcome: broken`.

**Phase 8 — Document and freeze the baseline**
- Lock the first successful `experiments/log.jsonl` entry as the baseline.
- Update README with achieved Fmax / fitness numbers.
- This is the point at which research iteration begins.

Total: ~17 days for one engineer + LLM pair, assuming the prior repo's
selftest.S, link.ld, crt0.S, CoreMark portme, and orchestrator code can be
copied (they are RTL-language-agnostic).

## 9. Style Rules (write these into `CLAUDE.md` on day one)

- **No `initial` blocks** in synthesizable code. Reset values come from a
  synchronous reset clause in `always_ff`.
- **No latches.** Every `always_comb` covers all branches, every `case` has
  a `default`, every `if` has an `else` (even if it just re-asserts the
  default).
- **Pipeline regs are explicit `always_ff @(posedge clock) if (reset) ...
  else ...` blocks.** No `RegInit(0.U.asTypeOf(...))` magic.
- **All RAM declarations carry `(* ram_style = "block" *)` (or its Gowin
  equivalent).** This makes BRAM inference deterministic across tools.
- **Decoder defaults to `illegal = 1'b1`.** A `case` arm clears it only
  after positively validating both opcode and funct fields.
- **Every module has a header comment** stating: purpose, latency (combo
  vs N-cycle), and which RVFI fields it contributes to.
- **`logic`, never `reg` or `wire`.** SystemVerilog has unified the type;
  use it.
- **No 2-state types (`bit`, `int`) in synthesizable code.** Use `logic`
  everywhere.
- **One module per file, named identically to the file.**
- **`core_pkg::*` import goes at the top of every RTL file that uses
  shared types. No `\`include` for shared headers.**

## 10. Bootstrap Prompt (paste into a fresh agent session)

> You are setting up a new repository: a 5-stage in-order RV32IM core
> written in SystemVerilog, verified by riscv-formal + Verilator cosim,
> with a CoreMark-on-FPGA fitness score on Gowin GW2A.
>
> Read `bootstrap-prompt.md` (this document). It contains:
> - The microarchitecture spec (§4)
> - The repo layout (§5)
> - 10 hard invariants you must enforce (§3)
> - The 8-phase build plan with acceptance criteria (§8)
> - Style rules for synthesizable SV (§9)
>
> Begin **Phase 0**: create the repo skeleton, `setup.sh`, and a stub
> `Makefile`. Acceptance criteria: `bash setup.sh` exits 0 and `make lint`
> reports no source files (because there are none yet). Do not start
> Phase 1 until the skeleton compiles cleanly under Verilator's lint mode
> with no source files in `rtl/`.
>
> Hard rules for this entire build:
> 1. SystemVerilog is the source of truth. No Chisel, no firtool, no Mill.
>    The `rtl/*.sv` files ARE the design.
> 2. Every phase ends with a passing test or eval gate. If you cannot
>    satisfy the acceptance criteria, **stop and report**, do not proceed
>    to the next phase.
> 3. The 10 invariants in §3 are non-negotiable. Each must be checked by
>    a test or eval gate that fails loudly on violation.
> 4. Reuse the prior repo's selftest.S, crt0.S, link.ld, CoreMark portme.c
>    (with bench markers), `tools/eval/cosim.py`, `tools/eval/formal.py`,
>    `tools/eval/fpga.py`, `tools/orchestrator.py` — they are
>    language-agnostic. Do NOT reuse anything under `chisel/`.
> 5. After every phase, commit with a message of the form
>    `phase-<N>: <one-line summary>` and update README's progress table.
>
> Confirm you understand by replying with: (a) the list of 10 invariants
> in your own words, (b) the phase you'll start with, and (c) the first
> three files you will create. Then begin.

---

## Appendix A — Files to Lift from the Prior Repo (verbatim)

These are RTL-language-agnostic and can be copied without modification:

- `bench/programs/selftest.S`
- `bench/programs/crt0.S`
- `bench/programs/link.ld`
- `bench/programs/Makefile`
- `bench/programs/coremark/` (entire directory, including the `baremetal/core_portme.c` and `core_portme.h` already updated for bench markers)
- `chisel/test/cosim/reference.py` → `test/cosim/reference.py`
- `chisel/test/cosim/run_cosim.py` → `test/cosim/run_cosim.py`
- `chisel/test/cosim/main.cpp` → `test/cosim/main.cpp` (already has OOB detection and bench markers)
- `tools/eval/cosim.py`
- `tools/eval/formal.py`
- `tools/eval/fpga.py`
- `tools/orchestrator.py`
- `tools/worktree.py`
- `tools/plot.py`
- `schemas/hypothesis.schema.json`
- `schemas/eval_result.schema.json`
- `formal/run_all.sh` (relocate path references from `chisel/` to `rtl/`)
- `formal/wrapper.sv` (port names already match what the new `core.sv` will expose)
- `formal/checks.cfg`
- `fpga/scripts/nextpnr_run.sh`
- `fpga/scripts/synth.tcl` (already points at `fpga/CoreBench.sv`)
- `fpga/constraints/Tang_Nano_20K.cst`
- `setup.sh` (delete the firtool / Mill / Chisel branches; keep Verilator,
  OSS CAD Suite, xPack toolchain)

## Appendix B — Files to Write from Scratch

Everything in `rtl/`. Everything in `test/` except cosim. Top-level
`Makefile`, `README.md`, `ARCHITECTURE.md`, `CLAUDE.md`.
