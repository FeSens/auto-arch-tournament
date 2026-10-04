# Per-benchmark scores, iter/s (exploratory, not pre-registered)

Higher is better. Compare within a row: kernels run different rep counts. Model columns are geomeans over the system's runs (pilot excluded); CoreMark is the loop's score, the kernels use the run's held-out Fmax. Reference cores run in the stage 2 simulators at their stage 1 Fmax with the same stall model.

## Overall (geomean of all 20 kernels)

| rank | system | all-20 geomean |
|---|---|---|
| 1 | Opus 5.5 (n=6) | 2,587 |
| 2 | Sonnet 5.5 (n=6) | 2,382 |
| 3 | VexRiscv MaxPerf (88 MHz) | 2,104 |
| 4 | GPT-6.1 Sol (n=6) | 2,006 |
| 5 | GPT-6 Astra (n=6) | 1,886 |
| 6 | VexRiscv NoCache (88 MHz) | 1,658 |
| 7 | VexiiRiscv (83 MHz) | 1,596 |
| 8 | GPT-5.5 (n=6) | 1,340 |
| 9 | Luna (n=6) | 1,297 |
| 10 | Hazard3 (50 MHz) | 1,120 |
| 11 | Ibex maxperf (45 MHz) | 967 |
| 12 | Ibex small (47 MHz) | 845 |
| 13 | ultraembedded riscv (44 MHz) | 832 |
| 14 | NEORV32 (92 MHz) | 798 |
| 15 | biRISC-V (27 MHz) | 736 |
| 16 | PicoRV32 (115 MHz) | 662 |

## Models

| benchmark | Opus 5.5 (n=6) | Sonnet 5.5 (n=6) | GPT-6.1 Sol (n=6) | GPT-6 Astra (n=6) | GPT-5.5 (n=6) | Luna (n=6) |
|---|---|---|---|---|---|---|
| CoreMark | 280 | 259 | 215 | 201 | 143 | 137 |
| dhrystone (held-out) | 222,102 | 203,785 | 171,350 | 162,286 | 115,642 | 110,401 |
| aha-mont64 (held-out) | 8,628 | 7,854 | 6,345 | 5,910 | 4,406 | 4,342 |
| crc32 (held-out) | 3,648 | 3,416 | 2,835 | 2,574 | 1,832 | 1,755 |
| matmult-int (held-out) | 1,169 | 1,080 | 906 | 852 | 602 | 609 |
| edn (held-out) | 2,093 | 1,843 | 1,526 | 1,506 | 1,069 | 1,081 |
| depthconv | 39,960 | 35,576 | 29,235 | 28,294 | 19,641 | 20,090 |
| huffbench | 372 | 348 | 291 | 268 | 188 | 184 |
| md5sum | 1,820 | 1,714 | 1,384 | 1,263 | 904 | 880 |
| nettle-aes | 1,613 | 1,516 | 1,249 | 1,159 | 864 | 820 |
| nettle-sha256 | 10,570 | 9,444 | 7,969 | 7,271 | 5,515 | 5,256 |
| nsichneu | 31,938 | 29,339 | 25,811 | 25,898 | 18,176 | 16,255 |
| picojpeg | 149 | 138 | 114 | 106 | 75.9 | 72.9 |
| qrduino | 149 | 136 | 114 | 107 | 77.8 | 74.0 |
| sglib-combined | 931 | 871 | 737 | 691 | 490 | 461 |
| slre | 3,585 | 3,299 | 2,756 | 2,572 | 1,901 | 1,764 |
| statemate | 78,950 | 72,099 | 61,289 | 56,792 | 40,768 | 39,253 |
| tarfind | 1,531 | 1,425 | 1,172 | 1,081 | 700 | 744 |
| ud | 39,884 | 36,588 | 34,743 | 36,413 | 22,518 | 21,624 |
| wikisort | 85.9 | 80.3 | 72.0 | 64.1 | 45.5 | 44.3 |
| xgboost | 23.3 | 21.8 | 18.4 | 16.9 | 12.5 | 11.8 |
| **geomean held-out 5** | **7,024** | **6,418** | **5,320** | **5,014** | **3,595** | **3,538** |
| **geomean new 15** | **1,854** | **1,712** | **1,450** | **1,361** | **964** | **928** |
| **geomean all 20** | **2,587** | **2,382** | **2,006** | **1,886** | **1,340** | **1,297** |

Includes runs with an out-of-range access on some kernels (correct results, a failure under the harness rule): Opus 5.5 (n=6). See analysis.md.

## Open-source reference cores

| benchmark | VexRiscv MaxPerf (88 MHz) | VexRiscv NoCache (88 MHz) | VexiiRiscv (83 MHz) | Hazard3 (50 MHz) | Ibex maxperf (45 MHz) | Ibex small (47 MHz) | ultraembedded riscv (44 MHz) | NEORV32 (92 MHz) | biRISC-V (27 MHz) | PicoRV32 (115 MHz) |
|---|---|---|---|---|---|---|---|---|---|---|
| CoreMark | 228 | 171 | 170 | 120 | 102 | 91.3 | 88.8 | 86.5 | 78.8 | 72.1 |
| dhrystone (held-out) | 212,486 | 146,435 | 138,838 | 95,000 | 82,319 | 68,247 | 68,205 | 60,431 | 52,718 | 52,591 |
| aha-mont64 (held-out) | 7,361 | 5,577 | 5,305 | 3,498 | 3,088 | 2,989 | 2,853 | 2,989 | 2,995 | 2,359 |
| crc32 (held-out) | 3,253 | 2,292 | 2,348 | 1,514 | 1,316 | 1,235 | 1,153 | 1,133 | 1,153 | 962 |
| matmult-int (held-out) | 984 | 742 | 722 | 536 | 443 | 334 | 356 | 330 | 304 | 272 |
| edn (held-out) | 1,853 | 1,363 | 1,264 | 944 | 794 | 596 | 654 | 606 | 595 | 493 |
| depthconv | 34,901 | 25,673 | 23,288 | 16,449 | 14,770 | 12,362 | 12,976 | 12,381 | 11,977 | 9,800 |
| huffbench | 311 | 231 | 214 | 159 | 133 | 116 | 112 | 108 | 99.4 | 91.4 |
| md5sum | 1,653 | 1,166 | 1,122 | 762 | 639 | 596 | 563 | 580 | 576 | 458 |
| nettle-aes | 1,374 | 1,156 | 1,142 | 696 | 616 | 582 | 568 | 548 | 585 | 423 |
| nettle-sha256 | 9,620 | 7,063 | 7,106 | 4,472 | 3,983 | 3,884 | 3,712 | 3,718 | 3,686 | 2,804 |
| nsichneu | 11,902 | 19,938 | 15,260 | 14,754 | 13,360 | 12,134 | 11,176 | 10,146 | 6,426 | 9,799 |
| picojpeg | 133 | 91.2 | 94.8 | 62.7 | 55.0 | 47.3 | 47.2 | 43.8 | 42.5 | 36.3 |
| qrduino | 125 | 94.7 | 91.4 | 63.3 | 56.8 | 51.2 | 49.8 | 48.5 | 41.8 | 38.8 |
| sglib-combined | 726 | 548 | 568 | 402 | 358 | 310 | 302 | 278 | 237 | 243 |
| slre | 2,553 | 2,196 | 1,877 | 1,508 | 1,359 | 1,181 | 1,163 | 1,075 | 997 | 904 |
| statemate | 71,637 | 51,968 | 51,906 | 33,635 | 29,238 | 23,654 | 24,385 | 21,454 | 22,351 | 17,949 |
| tarfind | 1,356 | 943 | 886 | 650 | 504 | 428 | 420 | 416 | 445 | 356 |
| ud | 33,300 | 27,378 | 31,727 | 20,191 | 15,830 | 14,096 | 14,005 | 15,534 | 10,788 | 12,915 |
| wikisort | 79.9 | 54.2 | 54.4 | 39.2 | 32.6 | 28.0 | 27.0 | 25.1 | 26.2 | 21.6 |
| xgboost | 13.9 | 15.3 | 14.3 | 10.0 | 9.1 | 8.3 | 7.8 | 7.5 | 5.9 | 6.1 |
| **geomean held-out 5** | **6,216** | **4,524** | **4,362** | **3,028** | **2,595** | **2,188** | **2,206** | **2,102** | **2,011** | **1,741** |
| **geomean new 15** | **1,467** | **1,186** | **1,141** | **804** | **696** | **616** | **601** | **578** | **527** | **479** |
| **geomean all 20** | **2,104** | **1,658** | **1,596** | **1,120** | **967** | **845** | **832** | **798** | **736** | **662** |

