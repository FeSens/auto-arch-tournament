# Extended benchmark suite (exploratory, not pre-registered)

35 finished champion runs x 20 benchmarks (5 held-out + 15 new Embench-IoT kernels); 10 reference cores.

Correct results: 700 of 700 champion runs (wrong or incomplete: none). Out-of-range access (CLAUDE.md invariant 6, a failure under the harness's rule): {'Opus 5.5 rep6': ['nettle-aes', 'nettle-sha256', 'nsichneu', 'picojpeg', 'qrduino', 'sglib-combined', 'slre', 'tarfind', 'ud', 'wikisort']}. Held-out cycle counts reproduced exactly for 175 of 175 (mismatches: none).

Opus 5.5 rep6: new-15 geomean 1971.0 from correct results; 2309.1 under the harness rule (geomean over the kernels it passes, all_validated false).

## Per system (scored runs; pilot excluded)

| system | n | held-out geomean | new-15 geomean | all-20 geomean | SD ln (new-15) |
|---|---|---|---|---|---|
| Opus 5.5 | 6 | 7024.2 | 1854.0 | 2586.6 | 0.087 |
| Sonnet 5.5 | 6 | 6417.5 | 1711.8 | 2382.0 | 0.077 |
| GPT-6.1 Sol | 6 | 5320.1 | 1449.7 | 2006.4 | 0.031 |
| GPT-6 Astra | 6 | 5013.6 | 1361.4 | 1886.0 | 0.102 |
| Luna | 6 | 3538.0 | 928.5 | 1297.2 | 0.158 |
| GPT-5.5 | 4 | 3420.2 | 920.9 | 1278.4 | 0.102 |

System order, held-out: Opus 5.5 > Sonnet 5.5 > GPT-6.1 Sol > GPT-6 Astra > Luna > GPT-5.5
System order, new-15:   Opus 5.5 > Sonnet 5.5 > GPT-6.1 Sol > GPT-6 Astra > Luna > GPT-5.5

## Rank intervals on the new-15 score (systems with 6 runs; 95% bootstrap)

| system | geomean new-15 | rank interval |
|---|---|---|
| Opus 5.5 | 1854.0 | 1 to 2 |
| Sonnet 5.5 | 1711.8 | 1 to 2 |
| GPT-6.1 Sol | 1449.7 | 3 to 4 |
| GPT-6 Astra | 1361.4 | 3 to 4 |
| Luna | 928.5 | 5 to 5 |

## Pairwise on the new-15 score (Welch on ln; Holm across the pairs shown)

Opus 5.5 vs Sonnet 5.5: ratio 1.083, 95% CI [0.974, 1.204], p = 0.1235, Holm p = 0.2470
Opus 5.5 vs GPT-6.1 Sol: ratio 1.279, 95% CI [1.167, 1.402], p = 0.0005, Holm p = 0.0037
Opus 5.5 vs GPT-6 Astra: ratio 1.362, 95% CI [1.205, 1.539], p = 0.0002, Holm p = 0.0019
Opus 5.5 vs Luna: ratio 1.997, 95% CI [1.684, 2.368], p = 0.0000, Holm p = 0.0002
Sonnet 5.5 vs GPT-6.1 Sol: ratio 1.181, 95% CI [1.089, 1.280], p = 0.0020, Holm p = 0.0065
Sonnet 5.5 vs GPT-6 Astra: ratio 1.257, 95% CI [1.118, 1.414], p = 0.0016, Holm p = 0.0065
Sonnet 5.5 vs Luna: ratio 1.844, 95% CI [1.558, 2.181], p = 0.0000, Holm p = 0.0004
GPT-6.1 Sol vs GPT-6 Astra: ratio 1.065, 95% CI [0.957, 1.185], p = 0.2006, Holm p = 0.2470
GPT-6.1 Sol vs Luna: ratio 1.561, 95% CI [1.324, 1.842], p = 0.0008, Holm p = 0.0047
GPT-6 Astra vs Luna: ratio 1.466, 95% CI [1.231, 1.746], p = 0.0009, Holm p = 0.0047

## Agreement

Run level (34 scored runs): Kendall tau between the held-out score and the new-15 score = 0.954.
Kernel level: the held-out leader (Opus 5.5) has the highest system geomean on 15 of 15 new kernels.

## Per kernel, system geomean iter/s (references at their stage 1 Fmax)

| kernel | Opus 5.5 | Sonnet 5.5 | GPT-6.1 Sol | GPT-6 Astra | Luna | GPT-5.5 | VexRiscv MaxPerf | VexRiscv NoCache | VexiiRiscv | Ibex maxperf | Ibex small | ultraembedded riscv | Hazard3 | biRISC-V | NEORV32 | PicoRV32 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dhrystone (held-out) | 222102 | 203785 | 171350 | 162286 | 110401 | 110946 | 212486 | 146435 | 138838 | 82319 | 68247 | 68205 | 95000 | 52718 | 60431 | 52591 |
| aha-mont64 (held-out) | 8628 | 7854 | 6345 | 5910 | 4342 | 4132 | 7361 | 5577 | 5305 | 3088 | 2989 | 2853 | 3498 | 2995 | 2989 | 2359 |
| crc32 (held-out) | 3648 | 3416 | 2835 | 2574 | 1755 | 1796 | 3253 | 2292 | 2348 | 1316 | 1235 | 1153 | 1514 | 1153 | 1133 | 962 |
| matmult-int (held-out) | 1169 | 1080 | 906 | 852 | 609 | 570 | 984 | 742 | 722 | 443 | 334 | 356 | 536 | 304 | 330 | 272 |
| edn (held-out) | 2093 | 1843 | 1526 | 1506 | 1081 | 997 | 1853 | 1363 | 1264 | 794 | 596 | 654 | 944 | 595 | 606 | 493 |
| depthconv | 39960 | 35576 | 29235 | 28294 | 20090 | 18040 | 34901 | 25673 | 23288 | 14770 | 12362 | 12976 | 16449 | 11977 | 12381 | 9800 |
| huffbench | 372 | 348 | 291 | 268 | 184 | 181 | 311 | 231 | 214 | 133 | 116 | 112 | 159 | 99 | 108 | 91 |
| md5sum | 1820 | 1714 | 1384 | 1263 | 880 | 869 | 1653 | 1166 | 1122 | 639 | 596 | 563 | 762 | 576 | 580 | 458 |
| nettle-aes | 1613‡ | 1516 | 1249 | 1159 | 820 | 807 | 1374 | 1156 | 1142 | 616 | 582 | 568 | 696 | 585 | 548 | 423 |
| nettle-sha256 | 10570‡ | 9444 | 7969 | 7271 | 5256 | 5254 | 9620 | 7063 | 7106 | 3983 | 3884 | 3712 | 4472 | 3686 | 3718 | 2804 |
| nsichneu | 31938‡ | 29339 | 25811 | 25898 | 16255 | 17751 | 11902 | 19938 | 15260 | 13360 | 12134 | 11176 | 14754 | 6426 | 10146 | 9799 |
| picojpeg | 149‡ | 138 | 114 | 106 | 73 | 73 | 133 | 91 | 95 | 55 | 47 | 47 | 63 | 42 | 44 | 36 |
| qrduino | 149‡ | 136 | 114 | 107 | 74 | 75 | 125 | 95 | 91 | 57 | 51 | 50 | 63 | 42 | 48 | 39 |
| sglib-combined | 931‡ | 871 | 737 | 691 | 461 | 472 | 726 | 548 | 568 | 358 | 310 | 302 | 402 | 237 | 278 | 243 |
| slre | 3585‡ | 3299 | 2756 | 2572 | 1764 | 1825 | 2553 | 2196 | 1877 | 1359 | 1181 | 1163 | 1508 | 997 | 1075 | 904 |
| statemate | 78950 | 72099 | 61289 | 56792 | 39253 | 38887 | 71637 | 51968 | 51906 | 29238 | 23654 | 24385 | 33635 | 22351 | 21454 | 17949 |
| tarfind | 1531‡ | 1425 | 1172 | 1081 | 744 | 663 | 1356 | 943 | 886 | 504 | 428 | 420 | 650 | 445 | 416 | 356 |
| ud | 39884‡ | 36588 | 34743 | 36413 | 21624 | 21240 | 33300 | 27378 | 31727 | 15830 | 14096 | 14005 | 20191 | 10788 | 15534 | 12915 |
| wikisort | 86‡ | 80 | 72 | 64 | 44 | 44 | 80 | 54 | 54 | 33 | 28 | 27 | 39 | 26 | 25 | 22 |
| xgboost | 23 | 22 | 18 | 17 | 12 | 12 | 14 | 15 | 14 | 9 | 8 | 8 | 10 | 6 | 8 | 6 |

‡ includes a run with an out-of-range access (a failure under the harness rule; the result was correct).

## Reference cores, geomean iter/s

| reference | Fmax MHz | held-out-5 | new-15 |
|---|---|---|---|
| VexRiscv MaxPerf | 87.764 | 6216 | 1467 |
| VexRiscv NoCache | 88.486 | 4524 | 1186 |
| VexiiRiscv | 82.898 | 4362 | 1141 |
| Hazard3 | 50.449 | 3028 | 804 |
| Ibex maxperf | 45.451 | 2595 | 696 |
| Ibex small | 47.107 | 2188 | 616 |
| ultraembedded riscv | 44.49 | 2206 | 601 |
| NEORV32 | 92.028 | 2102 | 578 |
| biRISC-V | 27.279 | 2011 | 527 |
| PicoRV32 | 114.828 | 1741 | 479 |
