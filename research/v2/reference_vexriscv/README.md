# VexRiscv reference in the V2 Gowin flow

External reference point for the V2 fitness: SpinalHDL VexRiscv, config
`GenFullNoMmuMaxPerf` (README "full max perf": RV32IM, 8 KB I$, 8 KB D$,
dynamic branch target prediction, full bypass, single-cycle barrel shifter,
MUL/DIV, CSR, debug module; published 2.57 CoreMark/MHz), VexRiscv commit
baf7dc82 (2026-09-24), SpinalHDL 1.13.0, unmodified generator.

Timed with the harness's own Gowin flow (tools/eval/gowin.py, imported
read-only): GW2AR-LV18QN88C8/I7, 5 ns target, place options 0/1/2, median.
`vex_bench.sv` mirrors fpga/core_bench_si.sv (same pins, LFSR instruction
data, bench_stall_gen ready sequence, 2048-word dmem in block RAM, LED = XOR of
the memory-side outputs). Cache refills are 8-beat bursts; the interrupt and
debug inputs come from LFSR bits so that logic stays in the netlist.

| place option | Fmax MHz | logic levels |
|---|---|---|
| 0 | 81.627 | 14 |
| 1 | 87.764 | 14 |
| 2 | 87.764 | 14 |
| **median** | **87.764** | |

Area (option 0): 2997 LUT4, 1186 FF (README: 1216 FF on Artix 7), 18 BSRAM
(caches, branch history, register file, bench dmem), 4 DSP.

Critical path: execute-stage SRC2 mux, 32-bit add/sub carry chain, bypass
back into the decode-to-execute RS2 register (the ALU bypass loop).

Implied score at the published 2.57 CoreMark/MHz: 87.76 x 2.57 = 225.5.
That IPC was measured with VexRiscv's own compiler flags and memory system,
not the bench's CoreMark build, so the score is indicative only.

Regenerate: clone VexRiscv, `sbt "runMain vexriscv.demo.GenFullNoMmuMaxPerf"`
(JDK 17), then `nice -n 19 python3 -B run_gowin.py` with VexRiscv/ next to it.
