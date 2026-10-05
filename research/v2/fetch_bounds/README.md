# Fetch-address bounds (post-campaign item 2, exploratory)

CLAUDE.md invariant 6 bounds every memory access to the 1 MiB memory plus the
MMIO window. Cosim (`test/cosim/main.cpp`) checks it on every cycle of the
programs it runs, but no formal check covers the instruction fetch address,
and on 10 of the 15 extended kernels Opus 5.5 rep6's champion fetches below
address 0 on a wrong path (results stay correct; NOTES 2026-10-04). This
check asks the question formally for every final.

`fetch_bounds.sv` (module `fetch_bounds_top`) wraps the design's `core` in an
environment and asserts `io_imemAddr < 0x100000` on every cycle after reset:

- The program is a fixed but arbitrary set of 64 words at [0, 256) (an
  `anyconst`, so the same word every time an address is fetched). Branch and
  JAL targets are constrained to aligned addresses inside that region, JALR
  only with rs1 = x0 and an in-range offset, and SYSTEM instructions are
  excluded. Fetches at or above 256 return `jal x0, 0`. So the program never
  leaves its region on any path, and an out-of-range fetch address can only
  come from the core itself (a mispredicted or miscomputed target).
- Data memory and both ready signals are free inputs: stalls are included,
  unlike the gate's formal wrapper, which ties ready to 1.
- The design is read as synthesis and cosim read it (no `RISCV_FORMAL`
  define, so formal-only branches are out) with `RISCV_FORMAL_ALTOPS`, which
  keeps the solver off 32-bit multipliers and dividers; data values are free
  here, so only divider latency changes. Memories become flip-flops and all
  state starts at zero, as in Verilator.

`fetch_bounds.py` runs SBY BMC with bitwuzla per design (`one`, or `all` for
the 42 finals, the GPT-6 Sol pilot and the textbook edit, 6 lanes, 90-minute
limit each); `summarize.py` builds `results/summary-d20.md`. Outcomes: PASS
(no out-of-range fetch within the depth), FAIL (a counterexample, with its
fetch-address trace), TIMEOUT (with the last step proven free of one).

## Results

See `results/summary-d20.md`. Depth 20 is a bounded check: PASS means no
out-of-range fetch within 20 cycles of reset from any 64-word program in this
class, not a proof for all time.

Depth 20, all 44 designs (2026-10-05, 12:08Z to 15:41Z): 36 PASS, 1 FAIL,
7 TIMEOUT.

- FAIL: Opus 5.5 rep6, at step 9. The program loops between addresses 0 and
  4; the fetch addresses are 0x0 0x0 0x0 0x4 0x8 0x0 0x0 0x4 0x0, then
  0xfffffffc. This is the wrong-path fetch below 0 seen on the extended
  kernels, reached from reset in 9 cycles.
- TIMEOUT after 90 minutes, no counterexample through steps 11 to 18: Opus
  rep1, rep2, rep5; Sonnet 5.5 rep4; GPT-6.1 Sol rep1, rep2; the GPT-6 Sol
  pilot.
- PASS: every GPT-6 Astra, GPT-5.5, GPT-6 Luna and no-lessons final, 5 of 6
  Sonnet 5.5, 4 of 6 GPT-6.1 Sol, 2 of 6 Opus, and the textbook edit. V0
  passes at depth 30 (1,121 s).

Operations note: SBY starts each solver engine in a process group of its
own, so a timeout that killed only the driver's group left the engines
running (they were killed by hand). Both drivers now also kill every process
whose working directory is inside the job's work directory.

`results/cex/opus_rep6-d20/`: the counterexample (SBY config, log, Yosys
witness `trace.yw`, testbench `trace_tb.v`, waveform `trace.vcd.gz`).
