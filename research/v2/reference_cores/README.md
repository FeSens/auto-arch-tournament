# Open-source reference cores in the V2 Gowin flow

Stage 1 of the reference comparison: Fmax and area of open-source RV32IM cores,
measured with the harness's own Gowin flow. Each score is Fmax times a
CoreMark/MHz published by someone else, so it is indicative only. Stage 2
(after the campaign) runs the bench's own `coremark.elf` and the five held-out
kernels on each reference in RTL simulation, replacing the published figure
with a measured one.

## Method

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

## Results

Score = Fmax x the CoreMark/MHz in the "CM/MHz" column. The basis column says
how far that figure is from the bench's build (rv32im, `-O3`, 2K,
`ITERATIONS=10`, single-cycle memory with the bench stall sequence).

| Core | Commit | Config | Fmax MHz | LUT4 | FF | CM/MHz | Basis | Score |
|---|---|---|---|---|---|---|---|---|
| VexiiRiscv | 4e38f271 | rv32im branchPredict, no caches | 85.950 | 3,499 | 1,614 | 2.99 | official, marked "too early" by its authors | 257.0 |
| VexRiscv MaxPerf | baf7dc82 | GenFullNoMmuMaxPerf, 8 KB I$ and D$ | 87.764 | 2,997 | 1,186 | 2.57 | official | 225.6 |
| Hazard3 | 8af99293 | rv32im, fast mul, branch predictor | 50.449 | 2,801 | 650 | 4.10 | official, different ISA (Zba/Zbb/Zbkb/Zbs, tuned flags) | 206.8 |
| VexRiscv NoCache | baf7dc82 | GenFullNoMmuNoCache | 88.486 | 2,519 | 957 | 2.30 | official | 203.5 |
| Ibex maxperf | e4bcf749 | 3-stage, 1-cycle mul, branch target ALU | 45.451 | 4,185 | 1,025 | 3.13 | official, same build as the bench | 142.3 |
| ultraembedded riscv | 7ae6f803 | upstream defaults | 44.490 | 4,952 | 2,320 | 2.94 | official, flags not stated | 130.8 |
| Ibex small | e4bcf749 | 2-stage, 3-cycle mul | 47.107 | 3,645 | 970 | 2.47 | official, same build as the bench | 116.4 |
| biRISC-V | 6af9c4be | dual-issue, upstream defaults | 27.279 | 17,560 | 6,402 | 4.1 | official, flags not stated | 111.8 |
| NEORV32 | 7f769c7a | multi-cycle, fast mul and shifter | 92.028 | 2,058 | 820 | 0.95 | official upper bound (rv32imc, caches) | 87.4 |
| PicoRV32 | ef203c2b | fast mul, div, barrel shifter | 114.828 | 2,486 | 930 | 0.553 | third-party (slow multiplier) | 63.5 |

## Per-core notes

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
