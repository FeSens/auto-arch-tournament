# EXP-2026-09-28-gowin-pilot (screening, not a calibration)

Question: under the vendor flow (Gowin EDA 1.9.11.03 Education, default place
option), how much does Fmax move under the same circuit-neutral padding that
moves nextpnr's Fmax by SD ~0.18 in ln?
Designs: V0, gpt-5_6-sol_rep1, gpt-5_6-terra_rep3 (research/v2/designs).
Variants: k in {0, 7, 14, ..., 56} (9). One build each.
Readout: SD of ln(Fmax) across the 9 variants per design, next to the nextpnr
figures for the same designs. Decides whether a Gowin-based V2 score needs a
median over variants at all; a full calibration follows if the flow is adopted.
