# Open-source reference cores in the V2 flow

Ten configurations of eight open-source RV32IM cores, scored the way the
bench scores an agent's core. Stage 1 measures Fmax and area with the
harness's own Gowin flow. Stage 2 runs the bench's own CoreMark ELF and the
five held-out kernel ELFs on each core in RTL simulation, with the harness's
bus-stall model and scoring. The headline numbers are in "Stage 2 results".

## Stage 2 results (measured)

CoreMark = Fmax x 1e6 x 10 iterations / bracketed cycles; held-out = geomean
over the five kernels of Fmax x 1e6 x reps / bracketed cycles (the formulas of
`tools/eval/fpga.py` and `tools/eval/holdout.py`). Every run passed the
harness's checks: the CoreMark CRCs and "Correct operation validated." (via
`validate_coremark_uart`), the held-out `status=PASS` line, both timing
markers, no out-of-range access.

| Core | Fmax MHz | LUT4 | CoreMark/MHz measured (published) | CoreMark | Held-out geomean iter/s |
|---|---|---|---|---|---|
| VexRiscv MaxPerf | 87.764 | 2,997 | 2.598 (2.57) | 228.0 | 6,216 |
| VexRiscv NoCache | 88.486 | 2,519 | 1.934 (2.30) | 171.1 | 4,524 |
| VexiiRiscv | 82.898 | 3,443 | 2.052 (2.99) | 170.1 | 4,362 |
| Hazard3 | 50.449 | 2,801 | 2.373 (4.10 with Zb*) | 119.7 | 3,028 |
| Ibex maxperf | 45.451 | 4,185 | 2.255 (3.13) | 102.5 | 2,596 |
| Ibex small | 47.107 | 3,645 | 1.939 (2.47) | 91.3 | 2,188 |
| ultraembedded riscv | 44.490 | 4,952 | 1.996 (2.94) | 88.8 | 2,206 |
| NEORV32 | 92.028 | 2,058 | 0.940 (0.95) | 86.5 | 2,102 |
| biRISC-V | 27.279 | 17,560 | 2.890 (4.1) | 78.8 | 2,012 |
| PicoRV32 | 114.828 | 2,486 | 0.628 (0.553, third-party) | 72.1 | 1,741 |

Two measured figures land on the published ones (VexRiscv MaxPerf 2.598 vs
2.57, NEORV32 0.940 vs 0.95), which checks the simulator and stall model. The
other published figures are higher because they were taken without bus
stalls, with other compilers and flags, or with extra ISA extensions.

Against the 32 finished agent runs (final CoreMark 113.0 to 308.8, held-out
2,881 to 7,770): VexRiscv MaxPerf scores above 21 of them on CoreMark and 23
on held-out. Every Opus 5.5 final and five of six Sonnet 5.5 finals beat it
on CoreMark; no GPT-6.1 Sol, GPT-6 Astra, Luna or GPT-5.5 final does.
VexRiscv NoCache and VexiiRiscv (about 170) sit inside the GPT-6 Astra range.
The other seven score below every agent final, except Hazard3, which beats
two finals on CoreMark and one on held-out. Five of those seven run at 27 to
50 MHz on this LUT4 part; NEORV32 and PicoRV32 are fast but multi-cycle.

### Stage 2 method

- `sim/ref_sim.cpp` is a Verilator testbench written to match
  `test/cosim/main.cpp --bench --istall --dstall`. It uses the same 1 MiB
  memory image, the same xorshift stall model and seed (about 22% of cycles
  stalled per port, imem drawn before dmem), the same UART and
  BENCH_START/STOP markers, the same 50M-cycle ceiling and the same final JSON
  line.
- Each core sits in a `sim/ref_top_<core>.sv` adapter on its own bus. A
  request is accepted on a ready draw, and the read data returns the next
  cycle (synchronous memory). For AHB (Hazard3), the access happens in the
  data phase. Cache refills (VexRiscv MaxPerf) stream one word per ready
  cycle.
- This differs from the agents' cores, which read memory combinationally (in
  the same cycle). A one-cycle response is the minimum most of these native
  protocols allow, and it is what the published figures assume.
- Reference cores have no common RVFI port, so a run ends at the first of:
  - the fetch of crt0's `ebreak` after BENCH_STOP;
  - a fetch outside memory (the trap vector, when the `ebreak` runs from an
    instruction cache);
  - 200k cycles with no bus access (VexRiscv's `ebreak` enters debug halt).

  Scores only use the marker cycles, so this rule only bounds the run.
- Ibex boots at boot_addr + 0x80, and VexRiscv at 0x80000000. Each fetches
  one `jalr x0, 0(x0)` at its reset PC (`--reset-pc`) before the timed
  window. VexiiRiscv is generated with reset vector 0 and the bench memory
  map instead (`--region`), and that build is the one timed in stage 1. The
  default-map build is kept in `results/vexiiriscv_defaultmap.json` (85.95
  MHz, 3,499 LUT4).
- ELFs: the clone-built `coremark.elf` (its code and data are identical to
  the main checkout's) and `bench/holdout/build/*.elf`, the ELFs the held-out
  scoring uses, copied to `~/refcores/elfs`.
- Run: `sim/ghdl_neorv32.sh` and `sim/ibex_sim_sv2v.sh <cfg>` (conversions),
  `sim/build.sh <core>`, then `sim/run_all.sh`. Results are in
  `results_sim/<core>.json`, with per-kernel cycles, reps and end reason.

## Stage 1 (Gowin Fmax and area)

### Stage 1 method

- Flow: `tools/eval/gowin.py`, imported read-only (`project_tcl`, `_run_gw_sh`,
  `parse_reports`, `summarize`). GW2AR-LV18QN88C8/I7, 5 ns target, place
  options 0/1/2 in parallel; the median Fmax is reported. Area comes from place
  option 0, as in the harness. Same method as `../reference_vexriscv/`.
- Bench: each core gets a wrapper in `benches/` that mirrors
  `fpga/core_bench_si.sv`. It keeps the same pins, takes instruction data from
  the same 32-bit LFSR and uses the `bench_stall_gen` ready sequence. The
  2048-word dmem is synchronous block RAM, and the LED is the XOR of the
  memory-side outputs. Each core's own bus is answered the way its own
  tightly coupled memory would answer it: accept when the stall sequence
  allows, respond one cycle later. Interrupt and debug inputs that a core
  exposes are driven from LFSR bits, so that logic stays in the netlist.
- Sources live outside the repo in `~/refcores/<repo>`, at the commits below.
  Results are in `results/<core>.json` (all three place options, with
  critical paths).
- Run: `nice -n 19 python3 -B run_ref.py <core> [...]`. Ibex is converted to
  Verilog first with `ibex_sv2v.sh <small|maxperf>` (sv2v v0.0.13, the
  conversion from Ibex's `syn/syn_yosys.sh`), and VexRiscv/VexiiRiscv are
  generated with sbt (JDK 17).
- These runs take no eval slot. They run at nice 19 beside the scored
  campaign, at most two cores (six Gowin processes) at a time.

### Stage 1 results

Score = Fmax x the CoreMark/MHz in the "CM/MHz" column (indicative; replaced
by the measured stage 2 scores above). The basis column says
how far that figure is from the bench's build (rv32im, `-O3`, 2K,
`ITERATIONS=10`, single-cycle memory with the bench stall sequence).

| Core | Commit | Config | Fmax MHz | LUT4 | FF | CM/MHz | Basis | Score |
|---|---|---|---|---|---|---|---|---|
| VexiiRiscv | 4e38f271 | rv32im branchPredict, no caches, bench memory map | 82.898 | 3,443 | 1,613 | 2.99 | official, marked "too early" by its authors | 247.9 |
| VexRiscv MaxPerf | baf7dc82 | GenFullNoMmuMaxPerf, 8 KB I$ and D$ | 87.764 | 2,997 | 1,186 | 2.57 | official | 225.6 |
| Hazard3 | 8af99293 | rv32im, fast mul, branch predictor | 50.449 | 2,801 | 650 | 4.10 | official, different ISA (Zba/Zbb/Zbkb/Zbs, tuned flags) | 206.8 |
| VexRiscv NoCache | baf7dc82 | GenFullNoMmuNoCache | 88.486 | 2,519 | 957 | 2.30 | official | 203.5 |
| Ibex maxperf | e4bcf749 | 3-stage, 1-cycle mul, branch target ALU | 45.451 | 4,185 | 1,025 | 3.13 | official, same build as the bench | 142.3 |
| ultraembedded riscv | 7ae6f803 | upstream defaults | 44.490 | 4,952 | 2,320 | 2.94 | official, flags not stated | 130.8 |
| Ibex small | e4bcf749 | 2-stage, 3-cycle mul | 47.107 | 3,645 | 970 | 2.47 | official, same build as the bench | 116.4 |
| biRISC-V | 6af9c4be | dual-issue, upstream defaults | 27.279 | 17,560 | 6,402 | 4.1 | official, flags not stated | 111.8 |
| NEORV32 | 7f769c7a | multi-cycle, fast mul and shifter | 92.028 | 2,058 | 820 | 0.95 | official upper bound (rv32imc, caches) | 87.4 |
| PicoRV32 | ef203c2b | fast mul, div, barrel shifter | 114.828 | 2,486 | 930 | 0.553 | third-party (slow multiplier) | 63.5 |

### Per-core notes

- **VexiiRiscv.** `sbt "Test/runMain vexiiriscv.Generate --xlen=32 --with-rvm
  --allow-bypass-from=0 --relaxed-branch --relaxed-btb --fetch-fork-at=1
  --with-btb --with-gshare --with-ras --regfile-async"`, the parameters of the
  `rv32im branchPredict` entry in `src/test/scala/vexiiriscv/scratchpad/Synt.scala`
  that the performance page reports. Every fetch and LSU command gets one
  response (stores included), with its id echoed. Critical path: execute
  source operand to the trap unit's tval register (14 levels).
- **VexRiscv NoCache.** `sbt "runMain vexriscv.demo.GenFullNoMmuNoCache"`.
  IBusSimple and DBusSimple respond one cycle after the command; stores have no
  response. Critical path: decode-to-execute RS2, ALU, then the
  execute-to-memory write data (the bypass loop).
- **Ibex.** Pinned to e4bcf749 (2026-08-11), the newest mainline commit with no
  CHERIoT RTL; later commits add CHERIoT capability hardware that the published
  figures did not have. Parameters are `ibex_configs.yaml` "small" and
  "maxperf", except `RegFile = RegFileFPGA` (Ibex's FPGA register file). C
  decode is always present in Ibex. `prim_clock_gating` is a pass-through, as
  in Ibex's FPGA examples. These are the only published figures measured the
  way the bench measures (rv32im binary, `-O3`, 2K, `crcfinal 0xfcaf`).
  Critical paths: ID, ALU, then register-file write (small); ID, ALU, branch
  target, then the prefetch FIFO (maxperf).
- **ultraembedded riscv.** `riscv_core` with the upstream defaults (MULDIV, load
  and multiply bypass, no MMU) and the flip-flop register file. The critical
  path is the core's load-bypass loop: E2 load result, ALU operand, branch
  compare, fetch PC (22 logic levels). The README's 2.94 relies on that bypass.
- **Hazard3.** `hazard3_cpu_2port`, AHB-Lite on both ports. ISA cut to RV32IM
  (no A, C, Zb*, debug, PMP, counters). The performance options match its
  `config_default.vh`: MUL_FAST, MUL_FASTER, MULH_FAST, MULDIV_UNROLL 2,
  FAST_BRANCHCMP, BRANCH_PREDICTOR, full bypass. RESET_REGFILE is 0, as
  recommended for FPGA. The published 4.10 needs the Zb* extensions and tuned
  flags; an rv32im figure is not published, so this row is an upper bound.
  The critical path is the ALU-computed load address driving the AHB address
  phase combinationally, then stall and decode (19 levels). That suits its
  ASIC target (RP2350, 150 MHz), not LUT4 fabric.
- **biRISC-V.** Upstream defaults: dual issue, 32-entry BTB, 512-entry BHT,
  RAS, flip-flop register file. It fetches 64 bits; the two words come from two
  LFSRs. It uses 85% of the part's LUT4. The critical path runs from the LSU
  through both issue pipes and the CSR unit (31 levels).
- **NEORV32.** `neorv32_cpu` only, through `benches/neorv32_cpu_flat.vhd`
  (flattens the bus records). Configured as rv32im with CPU_FAST_MUL_EN and
  CPU_FAST_SHIFT_EN, no C, no caches. The datasheet's best figure (0.95)
  includes C and caches, so it is an upper bound for this build.
- **PicoRV32.** ENABLE_FAST_MUL, ENABLE_DIV, BARREL_SHIFTER, no C, no IRQ. Its
  README gives only DMIPS/MHz (0.516, which `cores/picorv32/core.yaml` cites as
  CoreMark/MHz by mistake). The 0.553 is a third-party CRC-checked 2K run with
  the slower ENABLE_MUL multiplier.

Candidates not taken (from the shortlist research): DarkRISCV (no divide),
Kronos (no M), FemtoRV32 and Minerva (no CoreMark figure), CV32E40P (no
official figure), VeeR EL2 (vendor simulation claim only), SCR1 (adds little
over Ibex).
