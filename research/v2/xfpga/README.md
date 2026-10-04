# Cross-FPGA synthesis (amendment 15, part C)

Do the V2 designs, and the ranking of the systems, hold on a different FPGA
family and vendor flow? Each design is built with AMD Vivado 2026.1 for an
Artix-7 200T (xc7a200tsbg484-1, the slowest speed grade, the part on the
Nexys Video board) and its Fmax and area are recorded. The spec is
`research/runs/EXP-2026-09-28-v2-main/amendment_15.yaml`, section
`part_c_cross_fpga`; this directory implements it as written. All of part C
is exploratory.

## Method

- **Designs.** The 36 scored finals (`bench/v2/<system>/rep<1..6>/final-rtl`),
  the unscored GPT-6 Sol pilot final (listed, enters no test), V0
  (`cores/bench/rtl` at git tag `hwe-bench-v2.8.3`) and the ten reference
  configurations of `research/v2/reference_cores`. The part B baseline and the
  amendment 14 finals are added later with one command each (below).
- **Wrapper.** The files the Gowin fitness times. Agents, V0 and the baseline:
  the core's `*.sv` (with `core_pkg.sv` first, then the rest by name, the order
  of `rtl_sources()` in `tools/eval/gowin.py`), then `fpga/bench_stall_gen.sv`
  and `fpga/core_bench_si.sv` (every V2 design is nret 1). Reference cores: the
  exact source list, include paths and VHDL library of their stage-1 Gowin
  build (`~/refcores/gen/<core>/gowin_p0/build.tcl`; VexRiscv MaxPerf:
  `~/vexref/gen/gowin_p0/build.tcl`), with their bench wrappers from
  `research/v2/reference_cores/benches` (VexRiscv MaxPerf:
  `research/v2/reference_vexriscv/vex_bench.sv`). Ibex is the same sv2v output
  Gowin built (`~/refcores/gen/ibex_<cfg>_bench.v`), so the RTL is identical.
- **RTL as written.** Files are copied, never edited. No defines (the Gowin
  flow sets none). Every Verilog and SystemVerilog file (`.v`, `.sv`) is read
  as SystemVerilog (`read_verilog -sv`), as the Gowin projects read them
  (`-verilog_std sysv2017`); `.vhd` files are read as VHDL-2008, as in
  NEORV32's Gowin build (see "Flow decisions taken during the run"). Include directories
  are passed with `synth_design -include_dirs` (the reference cores' Gowin
  include paths; for the agents' cores, their own RTL directory, which their
  `` `include "core_pkg.sv" `` lines need). Gowin-only attributes such as
  `syn_ramstyle` are ignored by Vivado.
- **Flow** (`flow.tcl`, non-project batch mode, `set_param general.maxThreads 2`):
  1. `read_verilog` / `read_vhdl` in list order, then an XDC with
     `create_clock -period P -name clock [get_ports clock]` and
     `set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clock]` (the clock is
     taken as coming from a global buffer, as it would in a full design).
  2. `synth_design -mode out_of_context -top core_bench -part xc7a200tsbg484-1`,
     otherwise default options; the checkpoint is written.
  3. From that checkpoint: `opt_design`, `place_design -directive D`,
     `phys_opt_design`, `route_design`, all with default options except D.
  4. WNS = the slack of the worst setup path in the clock's own path group
     (`get_timing_paths -delay_type max -group clock`; recovery checks on
     asynchronous resets are in `**async_default**` and are recorded
     separately as `wns_all_groups`). Fmax = 1000 / (P - WNS) MHz.
- **Two passes.** Pass 1: P = 5.000 ns (the Gowin SDC's value), D = Default,
  gives F1. Pass 2: re-synthesize at P2 = round(0.95 x 1000 / F1, 3) ns, then
  three builds from that one synthesis with D = Default, Explore and
  ExtraTimingOpt. The design's Fmax is the median of the three (the Gowin
  score is likewise a median over three placements).
- **Area** from `report_utilization` of the pass-2 Default build: Slice LUTs,
  Slice Registers, LUT as Memory, Block RAM Tile, DSPs. A hierarchical report
  (`report_utilization -hierarchical`) gives the core instance's own LUTs and
  FFs, which is how a pruned core would show up (the wrapper observes only the
  memory-side outputs, so logic that only drives RVFI is removed, by design).
- **Failures.** A Vivado error in synthesis, placement or routing is a
  transfer failure: the status says which step, the ERROR lines are kept, and
  the design is not edited or retried.
- **Per build** the JSON keeps WNS, P, logic levels, start and end points,
  data-path, logic and net delay, skew, hold slack, route errors, step times
  and wall time.

Not matched to Gowin, by construction: a different vendor, LUT6 fabric instead
of LUT4, different RAM and DSP primitives. The bench's 2048-word dmem has an
asynchronous read in `core_bench_si.sv`, so Vivado builds it from distributed
RAM (256 RAM256X1S, 1024 LUTs as memory) in every agent, V0 and baseline
design; the reference benches use a synchronous dmem (block RAM). Out-of-context
timing has no I/O paths, like the Gowin wrapper's memory-side-only observation.

## Flow decisions taken during the run

The spec leaves these two points open. Both were settled on 2026-10-04 and
accepted by the operator's lead agent.

1. **Every `.v` and `.sv` file is read as SystemVerilog** (`read_verilog -sv`);
   VHDL stays VHDL-2008. Reason: the Gowin projects read every Verilog file as
   SystemVerilog (`set_option -verilog_std sysv2017`), so this mode gives Vivado
   the same source text in the same language. The first full run used Vivado's
   default, which picks the language from the extension (`.v` as
   Verilog-2001). In that mode both Ibex configurations failed synthesis on
   the sv2v output Gowin had built: `ERROR: [Synth 8-35] 'scramble_key_valid_i'
   is not a constant` (a `reg` declared with a non-constant initializer, legal
   in SystemVerilog). That run was stopped about 2 minutes in, before any
   design finished pass 1, and restarted in SystemVerilog mode. Its builds,
   together with the earlier smoke builds, are kept on the Vivado host in
   `~/hwe-xfpga/runs-aborted-verilog-mode`; none of their numbers are used.
   PicoRV32, built in both modes, gave identical results.
2. **WNS is the worst setup slack in the clock's own path group**
   (`get_timing_paths -delay_type max -group clock`), as the spec's "worst
   setup slack of the clock" says. Recovery checks on asynchronous resets
   fall in Vivado's `**async_default**` group; they are recorded separately
   (`wns_all_groups`, `worst_group_all`) and do not enter Fmax. In all 192
   builds of the first full run (48 designs x 4 builds), the worst path
   overall was in the clock group, so the two values are equal and the choice
   changed no number.

## Reading the numbers

- `core_luts` / `core_ffs` are the core instance's own cells. Vivado's
  hierarchy rebuild sometimes files core logic under the stall generator's
  instance (up to about 1,200 LUTs in one design), so `core_luts` is only a
  lower bound. `luts_excl_bench_top` (Slice LUTs minus the cells placed
  directly in `core_bench`, which for the agents is the dmem) does not
  depend on that attribution.
- Most agents' register files become flip-flops in Vivado (about 1,000 FFs),
  where Gowin's lower FF counts show it used RAM for some of them. Vivado
  ignores the `syn_ramstyle` hints. FF counts of identical RTL agree:
  reference cores within 1% of their Gowin counts.
- `p2_default_via_dmem` is true when the worst path of the pass-2 Default
  build runs through the bench's dmem. For the agents' designs that is the
  distributed-RAM read the core performs in the same cycle (single-cycle
  memory is part of the bench contract).
- `gowin_fmax` / `gowin_lut4` are for side-by-side reading only. Agents:
  the last accepted row of the run's `log.jsonl` whose fitness equals
  `final_fitness`; this is not necessarily a rescored value (the GPT-6 Sol
  pilot was rescored after incident 08). References: their stage-1 results.
  The analysis should take Gowin numbers from the scored records.

## Machines

Vivado runs on the operator's workstation (`omarchy`, 16 cores, 31 GB) in
`~/hwe-xfpga`, under `nice -n 10`, at most 6 Vivado jobs at once with 2 threads
each. The bench host only stages files, runs rsync/ssh and parses results.
Each design's `.dcp` checkpoints are deleted once its reports are parsed.

## Files

- `xfpga.py`: driver on the bench host (registry, staging, push, start,
  status, collect).
- `runner.py`: job runner on the Vivado host (two-pass schedule, job slots,
  parsing, cleanup).
- `flow.tcl`: the Vivado steps; `runner.py` writes a small `job.tcl` per job
  that sets its variables and sources this file.
- `designs.json`: the registry (name, group, top, source list or core RTL dir).
- `results/<design>.json`: everything recorded for one design, including the
  source list with SHA-256 per file, both passes and the area, plus the
  design's own Gowin numbers for side-by-side reading
  (`gowin_reference`; agents: the final champion's row in its `log.jsonl`).
- `results/summary.csv`: one row per design.

Staged copies live in `~/xfpga-stage` and pulled raw reports (Vivado logs,
timing and utilization reports) in `~/xfpga-raw` on the bench host; neither is
in the repo.

## Run

    cd research/v2/xfpga
    python3 -B xfpga.py init              # register the 48 built-in designs (once)
    python3 -B xfpga.py run --all         # stage + push + start in the background
    python3 -B xfpga.py status            # runner state and its log tail
    python3 -B xfpga.py collect           # pull, then results/*.json + summary.csv

`run NAME...` runs a subset; `--pass1-only` stops after pass 1 (smoke);
`--jobs N` sets the Vivado job limit (default 6). A design whose results are
complete for the same source hash is skipped, so a rerun only does what is
missing; `--force` rebuilds. Only one runner is allowed at a time.
`XFPGA_HOST`, `XFPGA_STAGE` and `XFPGA_RAW` override the host and local
directories.

## Add a design

A core that uses the standard nret 1 wrapper (part B baseline, ablation
finals):

    python3 -B xfpga.py add-core baseline_textbook --group baseline --rtl-dir path/to/rtl
    python3 -B xfpga.py add-core <system>_rep3 --group ablation --system <system> --rep 3 \
        --rtl-dir bench/v2/<system>/rep3/final-rtl
    python3 -B xfpga.py run baseline_textbook

(`--git-tag T` reads `--rtl-dir` from a git tag instead of the worktree.)
Any other design, as an ordered source list with its own top (relative paths
are taken from the repo root; `.v`/`.sv` are read as SystemVerilog, `.vhd` as
VHDL-2008):

    python3 -B xfpga.py add mycore --group reference --top core_bench \
        --include path/to/inc --lib neorv32=path/a.vhd src1.v src2.vhd bench.sv

## VexRiscv MaxPerf source provenance

The VexRiscv MaxPerf Verilog Vivado read (`~/vexref/VexRiscv/VexRiscv.v`,
sha256 42f9b653...a0ce88) was regenerated on 2026-10-04 from the same
VexRiscv commit (baf7dc82), SpinalHDL version and unmodified generator
(`GenFullNoMmuMaxPerf`) as the 2026-09-28 file the Gowin flow timed, which
was not kept for a byte comparison. The generator is deterministic for a
fixed commit and config, and the Vivado area matches the VexRiscv README's
Artix-7 figures for this configuration: the `cpu` instance has 1,212 FFs
against the README's 1,216, and the whole design 1,919 slice LUTs against
1,935 (the core instance alone 1,850).
