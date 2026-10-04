# Artix-7 cross-FPGA analysis (amendment 15 part C, exploratory)

## Systems

| system | held-out Gowin | held-out Artix-7 | Fmax Gowin | Fmax Artix-7 | Fmax ratio |
|---|---|---|---|---|---|
| Opus | 7,024 | 6,724 | 109.2 | 104.5 | 0.96 |
| Sol 6.1 | 5,320 | 6,543 | 89.6 | 110.2 | 1.23 |
| Luna | 3,538 | 4,245 | 62.1 | 74.5 | 1.20 |
| Astra | 5,014 | 6,236 | 81.8 | 101.8 | 1.24 |
| Sonnet 5.5 | 6,418 | 7,511 | 104.6 | 122.4 | 1.17 |
| GPT-5.5 | 3,595 | 4,385 | 65.3 | 79.7 | 1.22 |

Geometric means over each system's six runs; held-out in iterations/s, Fmax in MHz.

## Rank agreement

- Kendall tau-b, six systems, held-out: 0.867 (Fmax alone: 0.733)
- Spearman rho, 36 runs, held-out: 0.769 (Fmax alone: 0.677)
- Spearman rho, 36 runs plus 10 reference cores, held-out: 0.813

## Pre-registered tests on each FPGA

| pair | Gowin ratio [95% CI] | Gowin p (Holm) | Artix-7 ratio [95% CI] | Artix-7 p (Holm) | separates on |
|---|---|---|---|---|---|
| Opus vs Sol 6.1 (primary) | 1.320 [1.183, 1.473] | 0.0005 | 1.028 [0.813, 1.299] | 0.7978 | Gowin only |
| Luna vs Sol 6.1 (secondary) | 0.665 [0.568, 0.779] | 0.0007 | 0.649 [0.539, 0.780] | 0.0008 | both |
| Luna vs Opus (secondary) | 0.504 [0.425, 0.596] | 0.0000 | 0.631 [0.497, 0.802] | 0.0018 | both |
| Opus vs Astra (extension) | 1.401 [1.225, 1.602] | 0.0018 | 1.078 [0.855, 1.360] | 1.0000 | Gowin only |
| Opus vs Sonnet 5.5 (extension) | 1.095 [0.967, 1.238] | 0.4010 | 0.895 [0.709, 1.130] | 1.0000 | neither |
| Opus vs GPT-5.5 (extension) | 1.954 [1.700, 2.246] | 0.0000 | 1.533 [1.216, 1.934] | 0.0186 | both |
| Sol 6.1 vs Astra (extension) | 1.061 [0.949, 1.187] | 0.4999 | 1.049 [0.883, 1.247] | 1.0000 | neither |
| Sol 6.1 vs Sonnet 5.5 (extension) | 0.829 [0.754, 0.911] | 0.0076 | 0.871 [0.732, 1.037] | 0.5397 | Gowin only |
| Sol 6.1 vs GPT-5.5 (extension) | 1.480 [1.314, 1.667] | 0.0011 | 1.492 [1.256, 1.773] | 0.0042 | both |
| Luna vs Astra (extension) | 0.706 [0.595, 0.836] | 0.0074 | 0.681 [0.568, 0.816] | 0.0076 | both |
| Luna vs Sonnet 5.5 (extension) | 0.551 [0.468, 0.650] | 0.0003 | 0.565 [0.471, 0.678] | 0.0004 | both |
| Luna vs GPT-5.5 (extension) | 0.984 [0.828, 1.170] | 0.8402 | 0.968 [0.808, 1.160] | 1.0000 | neither |
| Astra vs Sonnet 5.5 (extension) | 0.781 [0.689, 0.885] | 0.0074 | 0.830 [0.700, 0.985] | 0.2119 | Gowin only |
| Astra vs GPT-5.5 (extension) | 1.395 [1.212, 1.605] | 0.0026 | 1.422 [1.201, 1.684] | 0.0076 | both |
| Sonnet 5.5 vs GPT-5.5 (extension) | 1.785 [1.566, 2.035] | 0.0000 | 1.713 [1.445, 2.030] | 0.0004 | both |

| rank | Gowin | rank interval | Artix-7 | rank interval |
|---|---|---|---|---|
| 1 | Opus 7,024 | 1 to 2 | Sonnet 5.5 7,511 | 1 to 2 |
| 2 | Sonnet 5.5 6,418 | 1 to 2 | Opus 6,724 | 1 to 4 |
| 3 | Sol 6.1 5,320 | 3 to 4 | Sol 6.1 6,543 | 1 to 4 |
| 4 | Astra 5,014 | 3 to 4 | Astra 6,236 | 2 to 4 |
| 5 | GPT-5.5 3,595 | 5 to 6 | GPT-5.5 4,385 | 5 to 6 |
| 6 | Luna 3,538 | 5 to 6 | Luna 4,245 | 5 to 6 |

## Fmax ratio, Artix-7 / Gowin

- Agents' finals: geomean 1.17 (range 0.80 to 1.51); reference cores 1.67 (1.33 to 1.94).
- Welch on ln(ratio), agents vs references: ratio of geomeans 0.698, 95% CI [0.634, 0.769], p = 1.4e-07.

## Reference cores

| core | held-out Gowin | held-out Artix-7 | Fmax Gowin | Fmax Artix-7 |
|---|---|---|---|---|
| vexriscv_maxperf | 6,216 | 10,246 | 87.8 | 144.7 |
| vexriscv_nocache | 4,524 | 8,772 | 88.5 | 171.6 |
| vexiiriscv | 4,362 | 6,699 | 82.9 | 127.3 |
| ueriscv | 2,206 | 4,060 | 44.5 | 81.9 |
| ibex_maxperf | 2,595 | 4,043 | 45.5 | 70.8 |
| hazard3 | 3,028 | 4,021 | 50.4 | 67.0 |
| neorv32 | 2,102 | 3,823 | 92.0 | 167.4 |
| biriscv | 2,011 | 3,803 | 27.3 | 51.6 |
| ibex_small | 2,188 | 3,597 | 47.1 | 77.5 |
| picorv32 | 1,741 | 2,774 | 114.8 | 182.9 |
