# Placement robustness (exploratory)

Held-out score = Fmax x the run's held-out cycle geomean (cycles do not depend on placement), so each view rescales each run's score by its Fmax under that view.

Per design, SD of ln Fmax over the six settings: median 0.022, max 0.075 (42 designs).

| view | primary Opus/Sol ratio [95% CI], p | extension pairs separating (of 12) | system order (held-out geomean) | Kendall tau vs scored |
|---|---|---|---|---|
| scored (median of p0, p1, p2 with route 0) | 1.320 [1.183, 1.473], p = 0.0005 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| median of all six settings | 1.306 [1.179, 1.446], p = 0.0003 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| best of six | 1.334 [1.195, 1.491], p = 0.0004 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| worst of six | 1.302 [1.173, 1.446], p = 0.0004 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 0, route 0 alone | 1.303 [1.174, 1.446], p = 0.0003 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 1, route 0 alone | 1.320 [1.183, 1.473], p = 0.0005 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 0, route 1 alone | 1.283 [1.155, 1.425], p = 0.0007 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 0, route 2 alone | 1.295 [1.166, 1.439], p = 0.0004 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 1, route 1 alone | 1.332 [1.187, 1.496], p = 0.0006 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |
| place 1, route 2 alone | 1.328 [1.197, 1.474], p = 0.0002 | 9 | Opus > Sonnet 5.5 > Sol 6.1 > Astra > GPT-5.5 > Luna | 1.000 |

Extension pairs that separate in the scored view: Opus/Astra, Opus/GPT-5.5, Sol 6.1/Sonnet 5.5, Sol 6.1/GPT-5.5, Luna/Astra, Luna/Sonnet 5.5, Astra/Sonnet 5.5, Astra/GPT-5.5, Sonnet 5.5/GPT-5.5; not separating: Opus/Sonnet 5.5, Sol 6.1/Astra, Luna/GPT-5.5.
