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
`1` = zero-wait, `0` = stalled. Both the CoreMark simulation and the timed
FPGA netlist drive them from the same pseudo-random sequence (about 22%
stalls on each bus, VexRiscv's "full no cache" methodology;
`fpga/bench_stall_gen.sv`). Logic that handles or hides stalls is
therefore part of the timed circuit: it costs area and can limit Fmax.

## Fitness

CoreMark iterations/second (median Fmax x iterations/cycle), 2K working set
(`TOTAL_DATA_SIZE=2000`), ITERATIONS=10, `-O3`, ~22% iStall+dStall.
Bracketed by MMIO writes to `0x10000100` (start) / `0x10000104` (stop) —
only cycles between the markers count.

`make fpga` runs the FPGA vendor's flow (Gowin EDA synthesis, place and
route and timing analysis; `tools/eval/gowin.py`) + CoreMark cosim. Median
Fmax across Gowin's placement options × CoreMark iter/cycle = fitness number
reported in `experiments/log.jsonl`. `make timing` prints the same Fmax with
the worst paths. V2 does not use Yosys or nextpnr for timing: nextpnr's model
for this part misses deep-arithmetic and LUT-RAM paths
(`research/v2/NOTES.md`). Yosys remains only inside riscv-formal.

The timed netlist observes only the memory-side outputs (fetch address,
data address, write data, write enables, read enable). RVFI outputs are
verification-only and are not timed: logic that only feeds RVFI is pruned
by synthesis, so optimizing it does not change the score.
