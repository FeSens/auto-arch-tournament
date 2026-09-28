# EXP-2026-09-27-v2-synth-flow: result

Ran on the Mac as pre-registered (3 designs x 9 variants x seeds 1-2; baseline
rows reused from the placement-noise runs). analyze_flow.py output:

| flow | V0 median MHz / LUT4 | sol median MHz / LUT4 | terra median MHz / LUT4 | sigma_flow |
|---|---|---|---|---|
| baseline (gw1n) | 119.31 / 9723 | 176.94 / 10247 | 69.95 / 7797 | 0.2914 |
| A -family gw2a | 119.31 / 9723 | 194.03 / 10247 | 140.31 / 7794 | 0.2762 |
| B -family gw2a -noabc9 | no placement: ~42,000 LUT4 > 20,736 | same | same | n/a |
| C -family gw2a -retime | 87.19 / 11125 | 86.25 / 11493 | 153.18 / 9400 | 0.2744 |

- B does not fit the device for any design or variant.
- C makes V0 and sol byte-identical across all 9 variants (SD 0, 86.68 MHz for
  V0) but costs ~27% Fmax and ~14% LUT4 there, and terra's SD rises to 0.48.
  Fails the 0.9x Fmax / 1.1x LUT4 bar.
- A vs C sigma differ by <1%: not distinguishable.

Decision (rule as registered): A. synth.tcl now passes -family gw2a.

Scope: n = 3 designs, Mac host. The run host builds different netlists from
the same inputs (research/v2/NOTES.md, 2026-09-28), so the magnitudes here do
not transfer; the decision rests on B not fitting and C losing Fmax/area,
which are large effects. Does not show that -retime is worse on every design.
