# EXP-2026-09-28-gowin-pilot: result (screening)

Gowin EDA 1.9.11.03 Education (Linux, gw_sh), part GW2AR-LV18QN88C8/I7,
one build per cell. Rows: runs.jsonl (6 rows lost to a mid-run script edit
are kept in failed_script_edit.jsonl and were rerun from a frozen copy).

| design | perturbation | Fmax (MHz) | logic / regs | SD ln Fmax | nextpnr SD ln, same designs |
|---|---|---|---|---|---|
| V0 | unused module, k=0..56 (9) | 5.140 all | 12312 / 460 all | 0 | 0.171 |
| gpt-5_6-sol_rep1 | unused module (9) | 5.131 all | 12772 / 527 all | 0 | 0.110 |
| gpt-5_6-terra_rep3 | unused module (9) | 4.989 all | 8337 / 452 all | 0 | 0.388 |
| opus-5_5_rep1 (V1 wrapper) | unused module (9) | 48.918 all | 2872 / 1257 all | 0 | n/a |
| opus-5_5_rep1 (V1 wrapper) | unused wires inside `core` (8) | 48.918 all | 2872 / 1257 all | 0 | n/a |
| opus-5_5_rep1 (V1 wrapper) | place_option 0 / 1 / 2 | 48.918 / 49.916 / 49.916 | same | 0.012 | n/a |

The vendor flow is insensitive to the circuit-neutral changes that move
nextpnr by SD 0.11-0.39; the placement algorithm moves it by ~2%.

Scope: these probes are pruned before mapping in Gowin, so they show Gowin
does not share nextpnr's name/order chaos; they do not bound how much a small
*functional* edit moves Gowin's Fmax. n = 4 designs, 3 near-identical
divider-limited ones. Decision support only; a calibration on the adopted
flow sets the acceptance margin.
