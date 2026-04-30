# Architecture

RV32IM CPU. Design any microarchitecture you like; the only requirements
are the I/O contract below and the invariants in `CLAUDE.md`.

## I/O contract

`rtl/core.sv` exposes a module named `core`. Required ports:

- `clock`, `reset`
- imem: `io_imemAddr [31:0]`, `io_imemData [31:0]`, `io_imemReady`
- dmem: `io_dmemAddr [31:0]`, `io_dmemRData [31:0]`, `io_dmemWData [31:0]`,
  `io_dmemWEn [3:0]`, `io_dmemREn`, `io_dmemReady`
- RVFI (NRET=2): per-channel `_0` / `_1` variants of every standard RVFI
  field — see `CLAUDE.md` invariant 1 for the exact set.

`io_imemReady` / `io_dmemReady` are single-bit bus-handshake signals:
`1` = zero-wait, `0` = stalled. The FPGA bench drives zero-wait; the
orchestrator's apples-to-apples cosim mode drives ~22% random stalls
on both buses to match VexRiscv's published "full no cache" methodology.

## Fitness

CoreMark/MHz, 6 KB working set, ITERATIONS=10, `-O3`, ~22% iStall+dStall.
Bracketed by MMIO writes to `0x10000100` (start) / `0x10000104` (stop) —
only cycles between the markers count.

`make fpga` runs yosys synth + 3-seed nextpnr P&R + CoreMark cosim. Median
Fmax across seeds × CoreMark iter/cycle = fitness number reported in
`experiments/log.jsonl`.
