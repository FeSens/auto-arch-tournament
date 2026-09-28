# EXP-2026-09-28-v2-noise-server: stopped, superseded (flow changed)

Stopped at 7 designs (gpt-6-sol_xhigh_rep1 14 of 17 variants) when V2 moved
FPGA timing from Yosys + nextpnr to Gowin EDA (research/v2/NOTES.md,
2026-09-28: nextpnr's timing misses deep-arithmetic and LUT-RAM paths). The
rows stay as the record of the V1 flow's noise on the run host.

analyze_noise_server.py, 5,000 Monte Carlo samples (measured, host numbers):

| design | median MHz | min | max | sigma_between | sigma_seed | sigma_9 |
|---|---|---|---|---|---|---|
| V0 | 134.91 | 90.55 | 150.42 | 0.181 | 0.040 | 0.105 |
| gpt-5_6-sol_rep1 | 180.67 | 128.86 | 210.88 | 0.115 | 0.050 | 0.043 |
| gpt-5_6-terra_rep3 | 106.42 | 54.43 | 158.58 | 0.417 | 0.052 | 0.311 |
| gpt-6-astra_max_rep1 | 141.82 | 122.49 | 148.41 | 0.049 | 0.044 | 0.020 |
| gpt-6-astra_max_rep2 | 164.15 | 87.84 | 190.13 | 0.319 | 0.062 | 0.221 |
| gpt-6-astra_max_rep3 | 162.88 | 153.49 | 176.74 | 0.041 | 0.060 | 0.024 |
| gpt-6-sol_xhigh_rep1 (14 variants) | 174.59 | 141.45 | 180.16 | 0.061 | 0.047 | 0.019 |

Pooled (RMS, n=7 designs): sigma_between 0.217, sigma_seed 0.051,
sigma_9 0.151, sigma_15 0.138. The pre-registered rule would have set the
margin to 2.33 x 0.151 = 0.352 in ln, i.e. a candidate must beat the
champion by 42%. Under that flow the loop could not have accepted realistic
single-step gains while controlling false accepts; the noise is dominated
by two designs (terra, astra rep2) whose netlists flip between mappings.
