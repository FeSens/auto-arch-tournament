# Analysis 4: lessons

| system | lessons | per run | from accepted | from rejected | from gate failures | lesson written for: accepted / rejected / gate-failed candidates | median length (chars) |
|---|---|---|---|---|---|---|---|
| Opus 5.5 | 261 | 45, 45, 43, 42, 42, 44 | 41 | 215 | 5 | 98% / 96% / 100% | 1154 |
| Sonnet 5.5 | 218 | 40, 32, 37, 37, 36, 36 | 45 | 167 | 6 | 96% / 80% / 43% | 958 |
| GPT-6.1 Sol | 144 | 25, 18, 21, 30, 25, 25 | 52 | 91 | 1 | 96% / 44% / 12% | 251 |
| GPT-6 Astra | 168 | 31, 30, 26, 23, 21, 37 | 54 | 113 | 1 | 96% / 54% / 33% | 256 |
| GPT-5.5 | 260 | 44, 45, 43, 44, 40, 44 | 28 | 217 | 15 | 100% / 96% / 88% | 237 |
| GPT-6 Luna | 177 | 28, 34, 29, 30, 29, 27 | 24 | 148 | 5 | 100% / 65% / 28% | 225 |
| all | 1228 |  | 244 | 951 | 33 |  |  |

Topic shares, multi-label (a lesson can count under several topics):

| system | divider | multiplier | branch prediction | fetch / caches | forwarding / hazards | formal / RVFI | cosim | process / tooling | area / resources | Fmax / critical path |
|---|---|---|---|---|---|---|---|---|---|---|
| Opus 5.5 | 23% | 33% | 62% | 48% | 82% | 8% | 16% | 43% | 72% | 99% |
| Sonnet 5.5 | 15% | 23% | 56% | 52% | 76% | 9% | 3% | 49% | 57% | 98% |
| GPT-6.1 Sol | 34% | 17% | 33% | 27% | 67% | 1% | 0% | 11% | 15% | 90% |
| GPT-6 Astra | 56% | 20% | 24% | 20% | 51% | 1% | 0% | 12% | 10% | 85% |
| GPT-5.5 | 10% | 12% | 37% | 28% | 65% | 10% | 1% | 5% | 4% | 78% |
| GPT-6 Luna | 8% | 7% | 34% | 32% | 45% | 3% | 0% | 5% | 6% | 75% |
| all | 22% | 19% | 43% | 36% | 66% | 6% | 4% | 22% | 30% | 88% |

Primary topic (the specific topic named first in the lesson; generic topics only when nothing specific matches):

| system | divider | multiplier | branch prediction | fetch / caches | forwarding / hazards | formal / RVFI | cosim | process / tooling | area / resources | Fmax / critical path | other |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Opus 5.5 | 5% | 13% | 31% | 15% | 29% | 2% | 0% | 4% | 0% | 0% | 0% |
| Sonnet 5.5 | 4% | 8% | 24% | 22% | 31% | 3% | 0% | 6% | 1% | 0% | 0% |
| GPT-6.1 Sol | 15% | 5% | 20% | 15% | 37% | 0% | 0% | 5% | 1% | 2% | 1% |
| GPT-6 Astra | 28% | 11% | 20% | 11% | 21% | 1% | 0% | 2% | 0% | 7% | 0% |
| GPT-5.5 | 7% | 8% | 32% | 13% | 25% | 3% | 0% | 3% | 2% | 6% | 1% |
| GPT-6 Luna | 7% | 6% | 26% | 12% | 29% | 0% | 0% | 2% | 0% | 16% | 2% |
| all | 10% | 9% | 27% | 15% | 28% | 2% | 0% | 4% | 1% | 5% | 0% |

Later hypotheses (rounds 2 to 15) whose title closely matches an earlier rejected or gate-failed candidate that has a lesson (Jaccard of title word sets):

| system | later candidates | J >= 0.4 | J >= 0.5 | J >= 0.6 | median content words per title | outcome of the J >= 0.5 repeats: accepted / rejected / gate failure |
|---|---|---|---|---|---|---|
| Opus 5.5 | 252 | 4 (2%) | 2 (1%) | 0 (0%) | 14 | 0 / 2 / 0 |
| Sonnet 5.5 | 252 | 6 (2%) | 1 (0%) | 0 (0%) | 12 | 0 / 1 / 0 |
| GPT-6.1 Sol | 252 | 1 (0%) | 1 (0%) | 0 (0%) | 7 | 1 / 0 / 0 |
| GPT-6 Astra | 252 | 2 (1%) | 0 (0%) | 0 (0%) | 7 | 0 / 0 / 0 |
| GPT-5.5 | 252 | 21 (8%) | 8 (3%) | 4 (2%) | 4 | 1 / 7 / 0 |
| GPT-6 Luna | 252 | 21 (8%) | 12 (5%) | 2 (1%) | 4 | 0 / 11 / 1 |

Title length differs by system (column above): two 4-word titles reach J = 0.6 with 3 shared words, two 14-word titles need about 11, so part of the higher GPT-5.5 and Luna rates is a length effect. The matched pairs below show what a match looks like.

Examples of matched pairs at J >= 0.5 (earlier -> later):

- GPT-5.5 rep2 (J=0.6): "ID-stage direct-JAL predictor" (rejected_below_margin) -> 1 rounds later "Target-carry direct-JAL predictor" (rejected_no_gain)
- GPT-5.5 rep2 (J=0.6): "ID-stage direct-JAL predictor" (rejected_below_margin) -> 8 rounds later "Opcode-fast direct-JAL predictor" (rejected_no_gain)
- GPT-6 Luna rep2 (J=0.6): "Register EX redirects at the pipeline boundary" (rejected_no_gain) -> 11 rounds later "Register the execute redirect boundary" (rejected_no_gain)
- GPT-6 Luna rep2 (J=0.6): "Learn direction by branch direction class" (rejected_no_gain) -> 2 rounds later "Learn only forward branch directions" (rejected_below_margin)
- Opus 5.5 rep6 (J=0.53): "Classic 5-stage: IF/ID register + explicit sync-read regfile so the BSRAM read leaves EX; ID-stage JAL/BTFN redirect" (rejected_lost_to_sibling) -> 1 rounds later "Take the regfile BSRAM DO out of EX: IF/ID register + ID-cycle sync regfile read on r3s0's flat EX, with ID-stage JAL/BTFN redirects" (rejected_below_margin)
- Opus 5.5 rep6 (J=0.5): "Next-fetch word predictor: 64-entry ahead-read L0 word table supplies the ID instruction on imem-stall cycles" (rejected_no_gain) -> 1 rounds later "Two-ahead pipelined fetch-word predictor: BSRAM word table read on a flop-predicted PC, used only on imem-stall cycles" (rejected_no_gain)
- Sonnet 5.5 rep6 (J=0.5): "1-cycle mispredict recovery (refetch target in the kill cycle) plus local-history two-level direction predictor" (rejected_lost_to_sibling) -> 1 rounds later "Retry 1-cycle mispredict recovery plus local-history direction predictor on the r6s1 99.9 MHz base" (rejected_no_gain)
- GPT-6.1 Sol rep2 (J=0.5): "LUT-factored four-bit divider launch seed" (rejected_lost_to_sibling) -> 1 rounds later "LUT-factored divider launch seed on the queued-fetch champion" (accepted)

Representative lessons:

- GPT-6.1 Sol rep6 (accepted, +735.1%): "Moving combinational DIV/REM (`/` and `%`) out of the shared ALU into a registered iterative divider removes their timing cost from ordinary instructions, letting Fmax gains outweigh CoreMark's added divide stalls."
- Opus 5.5 rep1 (rejected, +702.2%): "Moving MUL into the multi-cycle M-unit along with DIV/REM scored 97.23 iter/s, below the 103.21 of the divider-only sibling hyp-001; once the combinational `/`/`%` is gone, the single-cycle 33x33 DSP multiply is not on the ..."
- GPT-6 Luna rep5 (rejected, +5.7%): "Even a tiny direct-mapped BTB puts indexed tag/counter reads and target selection on the IF next-PC path, and their timing cost outweighed saved CoreMark loop-redirect bubbles."
- Sonnet 5.5 rep3 (accepted, +13.8%): "A depth-4 fetch queue (FD flop head feeding decode/regfile-read/load-use compare, 3-entry shifting flop FIFO, `accept = imem_ready && cnt != 3` so the pc CE no longer contains load_use/dmem_stall/ex_busy, redirect-cycle fetch ..."
- GPT-6 Astra rep1 (rejected, +4.2%): "Capturing completed MEM results and PC/immediate operands in ID reduces EX forwarding to two-input muxes but recovers too little Fmax for the one-entry fetch buffer's CoreMark cycle savings to clear the 4.6% acceptance margin."
