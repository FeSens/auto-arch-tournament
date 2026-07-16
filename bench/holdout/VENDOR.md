# bench/holdout/ vendored sources

Five bare-metal kernels held out from the optimization loop, used only to
score champion cores after the fact (E3 transfer-workload evaluation).
Four are ported from Embench-IoT; the fifth is the classic Dhrystone 2.1.

## Embench-IoT (aha-mont64, crc32, matmult-int, edn)

- Upstream: https://github.com/embench/embench-iot
- Commit: `09c2ed8c3b7008c95d08b038de4a3f6dc103ed70` (default branch `master`
  tip at fetch time, dated 2026-02-13 in upstream history)
- Retrieved: 2026-07-16
- License: GPL-3.0-or-later (per-file `SPDX-License-Identifier`, top-level
  `COPYING` is the GPLv3 text). License headers preserved verbatim in all
  vendored files.

Files copied (unmodified except the marked edit below):

| Vendored path | Upstream path |
|---|---|
| `embench/aha-mont64/mont64.c` | `src/aha-mont64/mont64.c` |
| `embench/crc32/crc_32.c` | `src/crc32/crc_32.c` |
| `embench/matmult-int/matmult-int.c` | `src/matmult-int/matmult-int.c` |
| `embench/edn/libedn.c` | `src/edn/libedn.c` |
| `embench/beebsc.c`, `embench/beebsc.h` | `support/beebsc.c`, `support/beebsc.h` |
| `embench/support.h` | `support/support.h` |

`beebsc.c`/`beebsc.h` (the BEEBS local `rand_beebs`/`srand_beebs`/malloc
shims) are vendored because `crc32` calls `rand_beebs`/`srand_beebs`
directly; the other three kernels don't reference them but `support.h`
transitively declares them, so they're included once for all four kernels
rather than duplicated per-kernel.

**HOLDOUT PORT edit** (identical, one line, in all four kernel `.c`
files): `benchmark_body()` was declared `static`; the `static` keyword was
dropped from both its forward declaration and its definition so each
kernel's `shim.c` can call it directly with a fixed internal count of 1
(`benchmark_body(1, 1)`), bypassing the `LOCAL_SCALE_FACTOR x
GLOBAL_SCALE_FACTOR` runtime-equalisation loop that `benchmark()`
normally drives. See the `/* HOLDOUT PORT: ... */` comment at each site.
No other line in these four files was touched.

`support.h` and `beebsc.c`/`beebsc.h` are vendored unmodified.

## Dhrystone 2.1 (dhrystone/)

- Source: `Keith-S-Thompson/dhrystone` GitHub mirror
  (https://github.com/Keith-S-Thompson/dhrystone), directory `v2.1/`,
  which reproduces the original 1990-02-14 `alt.sources` posting from
  TU Vienna EDP-Center of Reinhold P. Weicker's C version 2.1 (the
  canonical distribution; this mirror is a faithful re-post, not a
  derivative rewrite).
- Commit: `66bb9df1a5dea67f33437b856bf68ae52bd5c90f`
- Retrieved: 2026-07-16
- License: no formal license file accompanies the original 1988
  distribution; Dhrystone 2.1 has been freely redistributed and compiled
  into virtually every CPU benchmark suite since (SPEC, EEMBC, riscv-tests
  forks, etc.) under Weicker's original terms ("Distribute freely, and
  please give credit where credit is due"). Distribution attribution is
  preserved in full in the file header comments.

Files: `dhry_1.c`, `dhry_2.c`, `dhry.h` (originals: `dhry_1.c`, `dhry_2.c`,
`dhry.h` in the mirror's `v2.1/` directory).

**HOLDOUT PORT edits** (both files carry a `HOLDOUT PORT:` block comment
at the top explaining the change in full; summary here):

- `dhry_1.c`: upstream's `main()` combined one-time setup, the timed
  `for (Run_Index ...)` measurement loop, UNIX `times()`/`printf`/`scanf`
  instrumentation, and a results report in one function. Bare metal has
  none of stdio, scanf, or `times(2)`. `main()` was split into
  `Dhry_init()` (the one-time setup block) and `Dhry_one_run()` (one loop
  iteration, statement-for-statement identical to upstream's loop body).
  All `printf`/`scanf`/timing code and the results report were removed
  (this harness times externally via MMIO markers and verifies via
  `dhrystone/shim.c` instead of printed output). The one content change
  inside the timed body: the branch upstream marks "then, not executed"
  referenced the now-removed `Run_Index` loop variable; a static call
  counter (`Holdout_run_counter`) stands in, preserving the same
  never-taken control flow and statement shape. `#include <stdlib.h>`
  added for `malloc`'s real prototype (upstream used an untyped K&R
  `extern char *malloc ();`).
- `dhry.h`: the `TIMES`/`TIME`/`MSC_CLOCK`/`HZ` UNIX-timing block
  (`<sys/types.h>`/`<sys/times.h>`) was dropped, since nothing in the
  ported code calls `times()` anymore. `#include <stdio.h>` (whose
  comment claimed "for strcpy, strcmp", which is not what stdio.h
  provides) was corrected to `#include <string.h>`, the header that
  actually declares those functions. No type or struct definition was
  changed.
- `dhry_2.c`: vendored unmodified (no stdio/timing/main() dependencies).

Both kernels needing `strcmp`/`strcpy` (Dhrystone) and `memcpy`
(matmult-int, edn) get them from the toolchain's `nano.specs` libc, the
same newlib-nano build CoreMark's `bench/programs` targets already link
against.

## Not vendored

Embench's `support/main.c`, `support/board.c`, `support/chip.c`, and the
`dummy-benchmark/` scaffold were not vendored: this harness's own
`bench/holdout/support/main_wrapper.c` replaces Embench's driver entirely
(see `.superpowers/sdd/e3-task-1-brief.md` Step 3), and no chip/board
init is needed on this simulator target (matches `bench/programs`'s
`crt0.S`, which also skips it).
