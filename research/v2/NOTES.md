# HWE Bench V2 notes

Append-only. Plan: `PLAN.md`. Branch `v2`.

## 2026-09-27

### Stall generator in the timed wrapper (measured)
- `fpga/bench_stall_gen.sv` reproduces `test/cosim/main.cpp`'s backpressure (xorshift32, seed 0xDEADBEEF, imem draw then dmem draw per cycle, accept when `(s & 0x7F) < 100`) from registers. `tools/eval/test_bench_stall_gen.py`: identical to the C++ model for 100,000 cycles; accept rate on each port within 0.76 to 0.80.
- Standalone synthesis: 34 DFF, about 90 small LUTs, constant for every design.
- Both wrappers now drive `io_imemReady` / `io_dmemReady` from it, and the LED observes only memory-side outputs, so RVFI-only logic is pruned.
- Yosys rejects `return` in functions; the module uses Verilog-2005 function assignment.

### Instruction-level cosim gap (measured)
- `selftest.elf` retires 115 instructions. Before today it ran only without stalls; the CoreMark check (CRCs only) was the only stalled run.
- `tools/eval/cosim.py` now runs every trace ELF twice (no stalls; `--istall --dstall`). V0 and the Opus 5.5 final design pass both.
- Still open: a longer self-checking trace program (PLAN.md).

### Placement depends on file paths, not only on the circuit (measured, n=1 design)
- V0, same RTL, same toolchain binaries, seeds 1/2/3:
  - exact harness invocation (repo-relative paths, V1 `synth.tcl`): 128.72 / 127.03 / 123.02 MHz, LUT4 9563. Identical to every V1 retest.
  - absolute scratch paths, V2 `synth.tcl` (reads one extra, unused module): 142.71 / 118.58 / 132.43 MHz, LUT4 9913.
- Median moved 127.03 to 132.43 (+4.3%) with no change to the circuit. Two things changed at once (paths, extra module read), so the cause is not attributed to either.
- Consequences:
  - All comparisons must use the harness's exact relative-path invocation (`scripts/wrapper_compare.sh` now builds a repo-shaped tree).
  - Supports the V1 limitation that acceptance without a margin admits placement luck. The Phase 1 noise calibration should include netlist-neutral perturbations of this kind (renamed files, reordered reads, renamed signals), not only extra seeds.

### Other Phase 1 changes (tests pass: 344 passed, 2 skipped)
- nextpnr per-seed timeout (`NEXTPNR_TIMEOUT_SEC = 2700`), counted as a failed seed; test uses a hanging stand-in script and checks no process is left.
- FPGA results record LUT-RAM, BSRAM and DSP cells next to LUT4/DFF.
- Runner copies each run's final RTL to `final-rtl/` and stores the held-out geomean (`holdout_geomean_iter_s`) in the results row; scoring errors are recorded, not raised.
- Prompts: hypothesis agent gets its time budget and must write a complete draft within 5 minutes; implementation agent gets its budget, the fact that partial work is evaluated as-is, and a `make cosim` self-check.
- Pre-existing, unrelated: `tools/bench/test_provenance.py::test_provenance_records_commits_and_dirty` fails on `git tag` in a temp repo on this machine, with and without these changes.

### V1 vs V2 timing harness, repo-shaped invocation (measured, seeds 1/2/3)
`scripts/wrapper_compare.sh` (repo-relative paths). The V1 rows reproduce the logged V1 numbers exactly, which validates the replica.

| Design | Harness | Fmax per seed (MHz) | Median | LUT4 | DFF | LUT-RAM | BSRAM | DSP |
|---|---|---|---|---:|---:|---:|---:|---:|
| V0 | V1 | 128.72 / 127.03 / 123.02 | 127.03 | 9,563 | 1,866 | 0 | 4 | 1 |
| V0 | V2 | 97.20 / 100.66 / 111.21 | 100.66 | 9,723 | 1,437 | 0 | 4 | 1 |
| Opus 5.5 final | V1 | 302.21 / 278.71 / 315.76 | 302.21 | 3,128 | 1,491 | 36 | 4 | 1 |
| Opus 5.5 final | V2 | failed / failed / failed | - | 75,830 | 37,475 | 5,220 | 0 | 1 |

- V0 under V2: 429 fewer DFF (RVFI-only registers pruned), 160 more LUT4 (stall handling now kept), median Fmax -21%. On seed 2 the critical path runs from MEM/WB through forwarding into the ALU, not through the stall generator, so the drop is not attributed to one cause; the noise calibration has to separate it from placement variation.
- Opus 5.5 final under V2: the stall-only structures (4,096-entry instruction replay store, load cache, store buffer) are now synthesized. The design needs 75,830 LUT4 on a 20,736-LUT4 device and fails placement on every seed. Under V1 the same RTL reported 3,128 LUT4. Under a scoring rule in which cycles and timing describe the same circuit, V1's record design (983.24) would be a placement failure.

### Arithmetic and trace coverage: random trace programs (measured)
- `bench/programs/gen_random_trace.py`, seeds 1 to 3, committed as `random{1,2,3}.S`, built by `make bench`. Each starts with every M-extension op on every pair of 10 edge values, then random blocks (ALU, M ops, aligned loads/stores in a 64-byte window, forward branches and jumps, jalr, short counted loops). 9,982 to 11,003 retired instructions each before the edge matrix was added.
- V0 and the Opus 5.5 final design pass all three, with and without stalls.
- Planted bugs in V0:

| Bug | selftest | CoreMark CRCs | random (before edge matrix) | random (with edge matrix) |
|---|---|---|---|---|
| B1: DIVU by 0 returns 0 | pass | pass | fail | fail |
| B2: DIV INT_MIN / -1 returns 0 | pass | pass | pass | fail |
| B3: rs2 ignores MEM/WB forwarding | fail | fail | fail | fail |

  ALTOPS formal abstracts division, so under V1 gates B1 and B2 would have passed every check. Replaces the `test_alu.py` gate idea: module-level tests break on legitimate restructuring (agents rename and split the ALU), program-level traces do not.

### Provenance
- `tools/HARNESS_VERSION` (2.0.0-dev) in every results row; `env.json` records each tool's version and SHA-256 and a combined `toolchain_digest` (current: fe10e94c...).

## 2026-09-27: perturbation scoring in the harness (measured)

tools/eval/fpga.py now scores Fmax as the median over PERTURBATIONS, a list
of (k, seed) pairs: k=0 is the netlist `make` built, k>0 re-synthesizes with
the unused module zz_calib_pad (k assigns) read through SYNTH_PAD in
synth.tcl. The list stays at [(0,1),(0,2),(0,3)] (the V1 scheme) until the
calibration sets it.

Equivalence check (V0, harness path vs calibration driver, whose pad file
sat in the RTL dir instead of generated/var<k>/): k=0 seed 1 97.20 MHz,
LUT4 9723 in both; k=9 seed 1 136.71 MHz, LUT4 9705 in both. The pad file's
location does not matter, so the calibration's numbers apply to the
harness as-is (n=2 pairs, exact match).

Interim (2 of 7 designs complete, not a result): SD of ln(Fmax) across
variants 0.16-0.21 vs 0.04-0.07 across seeds within a variant.

## 2026-09-27: synthesis targets the wrong family; flow experiment

fpga/scripts/synth.tcl calls synth_gowin without -family, so Yosys maps for
its default gw1n while nextpnr places on GW2A-18C. The fabric is LUT4 in both
and the design places, but it is not the intended flow. This holds for all V1
results too.

The placement-noise calibration was stopped at 235 rows (V0, gpt-5_6-sol_rep1,
gpt-5_6-terra_rep3, gpt-6-astra_max_rep1 complete; astra rep2 partial): its
numbers describe gw1n synthesis and will be re-measured on the corrected
flow. Kept as the record of the V1-flow noise.

gpt-5_6-terra_rep3 k=9 (measured): LUT4 7830 vs 7782 unpadded, seeds 1-3 at
65.49 / 62.98 / 66.28 MHz vs 125.72 / 141.64 / 145.77. The neutral padding
changes the mapped netlist, not only placement.

EXP-2026-09-27-v2-synth-flow (pre-registered) compares -family gw2a, with
-noabc9, and with -retime on 3 designs x 9 variants x 2 seeds.
