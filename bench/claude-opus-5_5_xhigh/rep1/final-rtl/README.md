# Final RTL, Claude Opus 5.5 xhigh rep1

The `cores/bench/rtl/` files and `core.yaml` of the design this repetition ended on, copied verbatim from the run's Git history. The RTL is identical to the accepted r14s1 commit ("Late branch unit (v2 form)", fitness 983.24). It was written by the model; the operator did not edit it.

Scored results for this design: 3128 LUT4 (LUT-RAM, block RAM and DSP cells not counted), 1491 FF, Fmax median 302.21 MHz, 3,073,627 CoreMark cycles for 10 iterations. See [`../../README.md`](../../README.md) for how it was scored and the caveats, including stall-only logic that the FPGA wrapper constant-folds away.

To evaluate it, copy these files into `cores/<name>/rtl/` (and `core.yaml` into `cores/<name>/`) and run the normal gates. The per-change diffs are not published.
