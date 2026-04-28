# auto-arch-researcher

LLM-driven research environment that iteratively proposes microarchitectural
hypotheses on a 5-stage in-order RV32IM core written in **SystemVerilog**, then
grades each hypothesis on:

1. **Correctness** — riscv-formal + Verilator cosim against a Python ISS
2. **Performance** — CoreMark iter/sec on a Gowin GW2A FPGA target

The orchestrator accepts improvements (higher iter/sec) and rejects
regressions or broken hypotheses, building a chain of verifiably-correct
performance wins over time.

## Status

| Phase | What                                | Done? |
|-------|-------------------------------------|-------|
| 0     | Repo skeleton + toolchain           | ✓     |
| 1     | Combinational core (decoder + ALU)  | ✓     |
| 2     | Pipeline + Core top                 | ✓     |
| 3     | Verilator cosim                     | ✓     |
| 4     | riscv-formal                        | ✓     |
| 5     | Bench programs + CoreMark           | ✓     |
| 6     | FPGA fitness                        | ✓     |
| 7     | Orchestrator                        | ✓     |
| 8     | Baseline locked                     | ✓     |

## Baseline (locked, VexRiscv-comparable)

![CoreMark progress](experiments/progress.png)

First orchestrator iteration on the unmodified hand-SV pipeline, under
the same CoreMark methodology VexRiscv reports against ("full no cache,
2.30 CoreMark/MHz"): 2K data, `-O3`, `ITERATIONS=10`, ~22% iStall+dStall
random bus backpressure. CRCs verified against VexRiscv's pre-built
`coremark_rv32im.bin`.

| Metric                        | Value                                                |
|-------------------------------|------------------------------------------------------|
| **Fitness (CoreMark iter/s)** | **282.82**                                           |
| **CoreMark/MHz**              | **~2.23** (vs VexRiscv full-no-cache **2.30**)       |
| Fmax (median, 3 nextpnr seeds)| 127.03 MHz (128.72 / 127.03 / 123.02)                |
| LUT4                          | 9,563                                                |
| FF                            | 1,866                                                |
| Formal (riscv-formal, fast)   | 53 / 53 passed (ALTOPS — see [CLAUDE.md](CLAUDE.md)) |
| Cosim (selftest, RVFI trace)  | byte-identical to Python ISS                         |
| CoreMark CRCs (canonical 2K)  | `0xe714` / `0x1fd7` / `0x8e3a` / `0xfcaf`            |

Recorded in `experiments/log.jsonl` (entry `hyp-20260427-001`). All
subsequent hypotheses are scored relative to this fitness. The
pre-apples-to-apples baseline (6K data, `-O2`, zero-wait bus, 53.26
iter/sec) is preserved at `experiments/log.pre-vex.jsonl` for
reference but is not directly comparable.

## Quickstart

```sh
bash setup.sh             # one-time toolchain installer (macOS, ~1 GB if fresh)
make lint                 # verilator lint on rtl/
make test                 # cocotb unit tests
make cosim                # RVFI cosim vs Python ISS
make formal               # riscv-formal full suite
make fpga                 # 3-seed nextpnr + bracketed CoreMark cycles
make next                 # one tournament round (default 3 slots in parallel)
make loop N=10            # 10 tournament rounds
make report               # experiment summary
```

Each tournament round runs N hypotheses concurrently against the same
baseline, serializes the heavy eval phases (formal=1, fpga=1) through a
queue, and accepts only the round's highest-fitness winner; losing slots'
worktrees are discarded. Configure with `--tournament-size N` (default 3);
`N=1` reproduces the prior sequential behavior. The agent runtime is
codex by default; set `AGENT_PROVIDER=claude` to use Claude Code instead.

## Layout

```
rtl/          # SystemVerilog sources (the design)
test/         # cocotb unit tests + Verilator cosim harness
bench/        # selftest.S, crt0.S, link.ld, EEMBC CoreMark
formal/       # riscv-formal wrapper, checks.cfg, run_all.sh
fpga/         # core_bench.sv, synth.tcl, nextpnr scripts, constraints
tools/        # orchestrator, worktree manager, eval gates
schemas/      # hypothesis + eval-result JSON schemas
experiments/  # log.jsonl + per-iteration git worktrees
docs/         # bootstrap plan, architecture spec, design notes
```

## Hard contracts (do not break)

- Top module is named `core` and exposes the 32-signal RVFI port set.
- Decoder default is `isIllegal = 1`; cleared only inside validated arms.
- `rvfi_order` is strictly monotonic (`+1` per retirement).
- CoreMark is timed by the bench markers at `0x1000_0100` / `0x1000_0104`,
  not by raw cycle counts.
- All memory accesses live in `[0x00000000, 0x00100000)` (1 MiB code+data) or
  `[0x10000000, 0x10000200)` (UART + bench markers). Anything else is OOB
  and fails the eval.

The complete plan, microarchitecture, invariants, and phase acceptance
criteria are in [`docs/bootstrap-prompt.md`](docs/bootstrap-prompt.md). The
non-negotiable invariants are summarized in [`CLAUDE.md`](CLAUDE.md).

## Architecture

A textbook 5-stage in-order pipeline. **No** caches, **no** branch predictor,
**no** multi-issue. Those are research-loop hypotheses — not day-one features.

```
   ┌────┐  ┌────┐  ┌────┐  ┌─────┐  ┌────┐
   │ IF │→│ ID │→│ EX │→│ MEM │→│ WB │
   └────┘  └────┘  └────┘  └─────┘  └────┘
      │       │       ▲
      │       └───────┤    (forward EX→ID, MEM→ID)
      │               │
      └─── stall ←────┘    (load-use hazard)
```

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the per-stage spec.

## Tech stack

| Concern         | Tool                                                          |
|-----------------|---------------------------------------------------------------|
| RTL             | SystemVerilog (IEEE 1800-2017 synthesizable subset)           |
| Sim             | Verilator ≥ 5.0                                               |
| Unit tests      | cocotb ≥ 1.8 (Python harness over Verilator)                  |
| Formal          | YosysHQ riscv-formal (vendored as submodule); sby + bitwuzla  |
| Synth           | Yosys + `synth_gowin`                                         |
| Place & route   | nextpnr-himbaechel (Gowin GW2A-LV18QN88C8/I7 = Tang Nano 20K) |
| Cross-compiler  | xPack riscv-none-elf-gcc 15.x (symlinked to riscv32-unknown-elf) |
| Orchestrator    | Python 3.11+, jsonschema, pyyaml, matplotlib                  |

`setup.sh` installs everything into `.toolchain/`; tools already on PATH are
detected and reused.
