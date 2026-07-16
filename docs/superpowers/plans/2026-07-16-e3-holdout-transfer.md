# E3 Held-Out Workloads + Transfer-Score Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Score champion cores on workloads the tournament never optimized against (Dhrystone + 4 Embench-IoT kernels), producing a per-rep transfer score, with kernels validated on V0 and stripped from agent-visible clones.

**Architecture:** New `bench/holdout/` directory (kernel sources + Makefile reusing the existing crt0/link.ld contract read-only), a new `tools/eval/holdout.py` (build kernels, simulate each on a core via the existing `cosim_sim` Verilator harness, validate UART, compute per-kernel iter/s), and a new `tools/bench/transfer.py` (recover a rep's champion from `repo.bundle`, run holdout eval with the rep's recorded Fmax, emit a transfer row). Kernels are committed to main for reproducibility but removed from every fixture clone by `clone_fixture`, honoring the prereg guard.

**Tech Stack:** riscv32-unknown-elf-gcc (xPack 15.2.0, on PATH), Verilator `cosim_sim` harness (`test/cosim/main.cpp`, unmodified), Python 3.13, pytest.

## Global Constraints

- Branch `e3-transfer` only; never commit to main directly.
- Don't-touch list (CLAUDE.md) binds: NO edits to `bench/programs/`, `test/cosim/`, `formal/`, `fpga/`, `schemas/`, `Makefile`, `CLAUDE.md`. The holdout Makefile REFERENCES `bench/programs/crt0.S` and `bench/programs/link.ld` read-only; it never copies-and-modifies them.
- Held-out kernels never become an optimization target: `clone_fixture` must strip `bench/holdout/` from every clone (Task 2), and no holdout binary/score is ever written into a fixture clone or agent prompt.
- Gate 5 (eval validity): every kernel must produce its known-good output on V0 (`cores/baseline`) before any champion is scored (Task 4). A kernel that cannot be validated on V0 is excluded, loudly.
- No em-dash characters in any new text (commas/parens/periods/`--`).
- Tests: `python3 -m pytest tools/ -q` must stay green (baseline 229 passed, 2 skipped).
- Commit prefixes: `tools:` for tools/, `bench:` for bench/holdout/, `research:` for research/.
- Simulation flags must match the CoreMark fitness path exactly: `[sim_bin, elf, "50000000", "--bench", "--istall", "--dstall"]` (`tools/eval/fpga.py:117-119`), so held-out cycles are comparable to CoreMark cycles.
- Metric formula mirrors `tools/eval/fpga.py:174,272`: per-kernel `iter_s = fmax_mhz * 1e6 * reps / bracketed_cycles`, where `reps` is the kernel's fixed in-binary repetition count.
- Vendored kernel sources keep their upstream LICENSE headers and a `bench/holdout/VENDOR.md` pinning upstream repo + commit.

---

### Task 1: Vendor and port the five held-out kernels

**Files:**
- Create: `bench/holdout/Makefile`
- Create: `bench/holdout/support/holdout_port.h`, `bench/holdout/support/holdout_port.c`, `bench/holdout/support/main_wrapper.c`
- Create: `bench/holdout/dhrystone/` (dhry_1.c, dhry_2.c, dhry.h from Dhrystone 2.1)
- Create: `bench/holdout/embench/{aha-mont64,crc32,matmult-int,edn}/` (vendored from embench/embench-iot, pinned commit)
- Create: `bench/holdout/VENDOR.md`
- Test: build-level (Step 6), no pytest in this task.

**Interfaces:**
- Produces: `make -f bench/holdout/Makefile all` builds `bench/holdout/build/<kernel>.elf` for kernels `dhrystone aha-mont64 crc32 matmult-int edn`.
- Produces: each ELF, when run on `cosim_sim`, writes MMIO start marker, runs `HOLDOUT_REPS` repetitions of the kernel body, writes stop marker, prints exactly one line `HOLDOUT <kernel> reps=<R> status=PASS` (or `status=FAIL`) via UART putchar at `0x10000000`, then `ebreak`s (return from main hits `ebreak` in `bench/programs/crt0.S`).
- Consumes: `bench/programs/crt0.S`, `bench/programs/link.ld` (read-only), toolchain `riscv32-unknown-elf-gcc`.

- [ ] **Step 1: Vendor sources.** Fetch Embench-IoT at a pinned commit (upstream `https://github.com/embench/embench-iot`, use the default branch tip, record the SHA in VENDOR.md) and copy ONLY `src/aha-mont64/`, `src/crc32/`, `src/matmult-int/`, `src/edn/` (each is 1-2 C files plus the kernel's section of `support/`). Fetch Dhrystone 2.1 (classic sources, e.g. from the embench legacy or sim-any mirror; record origin). Strip nothing from license headers. Write `bench/holdout/VENDOR.md` listing upstream URL, commit SHA, retrieval date, per-kernel license.

- [ ] **Step 2: Write the port layer.** `bench/holdout/support/holdout_port.h`:

```c
#ifndef HOLDOUT_PORT_H
#define HOLDOUT_PORT_H
#include <stdint.h>
#define UART_TX      (*(volatile uint32_t *)0x10000000u)
#define BENCH_START  (*(volatile uint32_t *)0x10000100u)
#define BENCH_STOP   (*(volatile uint32_t *)0x10000104u)
void ho_putc(char c);
void ho_puts(const char *s);
void ho_putu(unsigned v);
#endif
```

`holdout_port.c` implements the three helpers (byte writes to UART_TX; `ho_putu` prints decimal). No printf, no libc I/O.

- [ ] **Step 3: Write the wrapper.** `bench/holdout/support/main_wrapper.c`: each kernel is compiled with `-DKERNEL_NAME="<name>" -DHOLDOUT_REPS=<R>` and provides `int holdout_init(void); void holdout_body(void); int holdout_verify(void);` (thin shims per kernel mapping to Embench's `initialise_benchmark/benchmark_body/verify_benchmark`, and for Dhrystone to a fixed-iteration run plus its built-in checks). Wrapper:

```c
#include "holdout_port.h"
int main(void) {
  if (holdout_init() != 0) { ho_puts("HOLDOUT " KERNEL_NAME " reps=0 status=FAIL\n"); return 1; }
  BENCH_START = 1;
  for (unsigned i = 0; i < HOLDOUT_REPS; i++) holdout_body();
  BENCH_STOP = 1;
  ho_puts(holdout_verify() ? "HOLDOUT " KERNEL_NAME " reps=" REPS_STR " status=PASS\n"
                           : "HOLDOUT " KERNEL_NAME " reps=" REPS_STR " status=FAIL\n");
  return 0;
}
```

(Define `REPS_STR` via stringize macros.) Per-kernel shim files live next to the vendored sources (e.g. `bench/holdout/embench/crc32/shim.c`).

- [ ] **Step 4: Makefile.** Mirror `bench/programs/Makefile` conventions exactly (same CROSS, `-march=rv32im -mabi=ilp32 -static -nostartfiles -specs=nano.specs -specs=nosys.specs -T bench/programs/link.ld`, plus `bench/programs/crt0.S` in the sources). One target per kernel into `bench/holdout/build/`. Choose `HOLDOUT_REPS` so each kernel runs 1M-10M cycles on V0 (fits the 50M ceiling with margin; calibrate in Step 6, start with dhrystone=300, mont64=40, crc32=60, matmult-int=15, edn=25 and adjust). Memory fit: link.ld gives 128K FLASH + 64K RAM; all five kernels fit (largest is matmult-int matrices, well under 64K).

- [ ] **Step 5: Build.** `make -f bench/holdout/Makefile all` builds five ELFs with zero warnings. Fix until clean.

- [ ] **Step 6: Calibrate + smoke on V0.** Build V0's simulator if absent (`bash test/cosim/build.sh` pattern via `python3 -m tools.eval.fpga` does it; simplest: run `make fpga TARGET=baseline` once or reuse existing `cores/baseline/obj_dir/cosim_sim`). For each kernel: `cores/baseline/obj_dir/cosim_sim bench/holdout/build/<k>.elf 50000000 --bench --istall --dstall`, confirm the JSON tail has `"ebreak":true, "oob":false, "bench_bracketed":true`, UART contains `status=PASS`, and bracketed cycles are in [1M, 10M]. Adjust `HOLDOUT_REPS` and rebuild until all five comply. Record final reps + V0 cycles per kernel in the task report.

- [ ] **Step 7: Commit.** `git add bench/holdout && git commit -m "bench: vendor held-out kernels (dhrystone + 4 embench) with MMIO port layer"`

### Task 2: Strip holdout from agent-visible clones

**Files:**
- Modify: `tools/bench/runner.py` (`clone_fixture`, after the existing post-clone fixes around lines 250-330)
- Test: `tools/bench/test_runner.py`

**Interfaces:**
- Produces: any clone made by `clone_fixture` contains no `bench/holdout/` regardless of ref.

- [ ] **Step 1: Failing test.** In `test_runner.py`, extend the existing clone_fixture test fixture repo with a committed `bench/holdout/x.c`; assert the clone has no `bench/holdout` directory. Run, expect FAIL.
- [ ] **Step 2: Implement.** In `clone_fixture`, after the tag-ambiguity fix: `shutil.rmtree(dest/"bench"/"holdout", ignore_errors=True)` plus a comment citing the E3 prereg guard (held-out kernels must never be agent-visible). Run test, expect PASS.
- [ ] **Step 3: Full suite + commit.** `python3 -m pytest tools/ -q` green. `git commit -m "tools: strip bench/holdout from fixture clones (E3 held-out guard)"`

### Task 3: Holdout eval module

**Files:**
- Create: `tools/eval/holdout.py`
- Test: `tools/eval/test_holdout.py`

**Interfaces:**
- Produces: `run_holdout(worktree: str, target: str, fmax_mhz: float) -> dict` returning `{"kernels": {name: {"cycles": int, "reps": int, "iter_s": float, "validated": bool}}, "geomean_iter_s": float, "all_validated": bool}`; CLI `python3 -m tools.eval.holdout <worktree> <target> <fmax_mhz>` printing that JSON.
- Consumes: `bench/holdout/build/*.elf` (built via the Task 1 Makefile if missing), `cores/<target>/obj_dir/cosim_sim` (built via the same path `tools/eval/fpga.py` uses if missing).

- [ ] **Step 1: Failing tests.** Parser tests with canned sim JSON+UART (PASS line, FAIL line, missing bracket, oob) asserting per-kernel validation and `iter_s = fmax_mhz * 1e6 * reps / cycles`; geomean over validated kernels only; `all_validated` false if any kernel fails. Run, expect FAIL (module absent).
- [ ] **Step 2: Implement.** Structure mirrors `tools/eval/fpga.py:run_coremark_ipc` (reuse its marker-JSON parsing approach; import nothing private, copy the small parse into holdout.py with a comment naming the source). Kernel list is a module constant `HOLDOUT_KERNELS = ("dhrystone", "aha-mont64", "crc32", "matmult-int", "edn")`. Build steps invoked via subprocess with clear FATAL messages. Validation: UART must contain `HOLDOUT <kernel> reps=<R> status=PASS` and the sim JSON must have `ebreak:true, oob:false, bench_bracketed:true`.
- [ ] **Step 3: Suite + commit.** `git commit -m "tools: holdout eval module (build, simulate, validate, score held-out kernels)"`

### Task 4: V0 validation gate + E3 prereg

**Files:**
- Create: `research/runs/EXP-2026-07-e3-transfer/prereg.yaml`
- Create: `bench/holdout/v0_expected.json` (V0 cycles + status per kernel, the gate-5 record)
- Test: executes and records; no pytest.

- [ ] **Step 1: Run the gate.** `python3 -m tools.eval.holdout . baseline <V0_fmax>` with V0 fmax 127.03 (the recorded baseline). All five kernels must report `validated: true`. Save the full JSON to `bench/holdout/v0_expected.json`.
- [ ] **Step 2: Prereg.** Write `research/runs/EXP-2026-07-e3-transfer/prereg.yaml` verbatim from the stub in `research/paper_revision_plan.md` E3 section (question/hypothesis/primary_metric/success_rule), adding `run_id: EXP-2026-07-e3-transfer`, `baseline_run_id: V0 (bench/holdout/v0_expected.json)`, `kernels: [dhrystone, aha-mont64, crc32, matmult-int, edn]`, `config: {sim_flags: "--bench --istall --dstall", reps_per_kernel: <from Task 1>}`. WRITE-ONCE after commit.
- [ ] **Step 3: Commit.** `git commit -m "research: preregister E3 transfer evaluation; record V0 held-out gate"`

### Task 5: Transfer scorer over rep bundles

**Files:**
- Create: `tools/bench/transfer.py`
- Test: `tools/bench/test_transfer.py`

**Interfaces:**
- Produces: CLI `python3 -m tools.bench.transfer bench/<model>/rep<N> [--out research/transfer/results.jsonl]`: clones `repo.bundle` to scratch, checks out HEAD (final champion), builds its `cores/bench` simulator, reads the rep's champion Fmax from the rep's `log.jsonl` (the LAST `outcome == "improvement"` row's `fmax_mhz`; fall back to `summary.json` `best_fmax_mhz` with a warning if none), runs `run_holdout(clone, "bench", fmax)`, and appends `{"model", "rep", "champion_fmax_mhz", "kernels", "geomean_iter_s", "coremark_iter_s" (from summary final_fitness), "timestamp"}` to the out file. Exits 3 with a clear message when `repo.bundle` is missing (older reps).
- Consumes: Task 3's `run_holdout`; rep dir layout documented in the recon (log.jsonl fields `fitness, fmax_mhz, outcome`; `summary.json` `final_fitness best_fmax_mhz`).

- [ ] **Step 1: Failing tests.** Fabricate a mini rep dir (tiny git repo bundled with `git bundle create`, containing a `cores/bench/rtl` marker file; fake log.jsonl with improvement rows) and assert: bundle-clone happens, correct fmax row chosen (last improvement, not best), missing-bundle exits 3, output row schema complete. Mock `run_holdout`.
- [ ] **Step 2: Implement.** Scratch clones under the caller's TMPDIR, always cleaned in a finally block. No mutation of the rep dir.
- [ ] **Step 3: Suite + smoke + commit.** Full pytest green, then real smoke: `python3 -m tools.bench.transfer bench/gpt-5_6-sol/rep1 --out /tmp/e3-smoke/results.jsonl` must produce one row with five validated kernels (this is the first real champion transfer score; report the numbers, n=1, no adjectives). `git commit -m "tools: transfer scorer over rep bundles (E3)"`

---

**Self-review notes:** Task 1 has no pytest because its deliverable is ELF artifacts gated by the V0 smoke in Step 6 and permanently by Task 4's gate record. Type consistency: `run_holdout(worktree, target, fmax_mhz)` is consumed by Task 5 exactly as defined in Task 3. The don't-touch list is respected: holdout reuses crt0/link.ld by path reference; `test/cosim/main.cpp` is never edited (its existing marker/UART JSON is sufficient).
