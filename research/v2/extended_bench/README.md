# Extended benchmark suite (exploratory)

Every finished V2 champion and every reference core run on 20 bare-metal
benchmarks:

- the five held-out kernels the pre-registered score uses (Dhrystone 2.1,
  aha-mont64, crc32, matmult-int, edn);
- the 15 other Embench-IoT kernels at the commit `bench/holdout` vendors
  from (09c2ed8c): depthconv, huffbench, md5sum, nettle-aes, nettle-sha256,
  nsichneu, picojpeg, qrduino, sglib-combined, slre, statemate, tarfind, ud,
  wikisort, xgboost.

No agent saw any of these programs, and none of the 15 enters any
pre-registered result. This is an exploratory check of whether the ranking
holds on unseen workloads. It is not a replacement for the pre-registered
analysis.

Results: `results/analysis.md` (tables), `results/analysis.json`,
`results/champions.json` and `results/references.json` (per run and kernel:
cycles, reps, iter/s, checks).

## Method

- **ELFs** (`build_elfs.py`). The 15 new kernels are ported the way
  `bench/holdout/VENDOR.md` ports its four: `static` is dropped from
  `benchmark_body`, and a shim calls `benchmark_body(1, 1)` once per rep.
  The driver is `bench/holdout/support/main_wrapper.c` (timing markers,
  HOLDOUT_REPS bodies, one PASS/FAIL line from `verify_benchmark`). They
  use the held-out Makefile's compiler and flags, crt0 and link script.
  wikisort needs `-std=gnu17` because it typedefs `bool`, a keyword in
  GCC's default C23 (the Makefile pins Dhrystone to gnu89 the same way).
  The five held-out ELFs are byte-identical copies of
  `bench/holdout/build/`. Nothing is written into `bench/`; sources and
  ELFs live under `~/extbench`.
- **Reps** (`reps.json`). Each new kernel's rep count is set so it runs
  about 3M timed cycles on VexRiscv NoCache. The held-out five run 1.8M to
  3.6M there.
- **Champions** (`run_champions.py`). Each run's saved `final-rtl/` is built
  with the verilator command of `test/cosim/build.sh` and the repository's
  `test/cosim/main.cpp` (NRET=1). Each ELF runs with the held-out
  invocation (50M-cycle ceiling, `--bench --istall --dstall`). The score is
  the run's held-out Fmax x 1e6 x reps / bracketed cycles.
- **Build check.** For all 35 runs, the five held-out kernels reproduce the
  scored cycle counts exactly (175 of 175).
- **References** (`run_refs.py`). The stage 2 simulators of
  `../reference_cores` run each ELF with the same stall model, at their
  stage 1 Fmax.
- **Analysis** (`analyze.py`). It uses the Welch, bootstrap rank-interval
  and Holm functions of `research/v2/scripts/analyze_main.py`. Two views are
  reported:
  - *correct results* (performance): every kernel that ran to completion
    with a correct result;
  - *the harness rule*: an out-of-range access (CLAUDE.md invariant 6)
    fails the kernel, and the geomean is taken over the kernels that pass,
    with `all_validated` false.

## Findings (GPT-5.5 at 4 of 6 runs; rerun when it finishes)

- **Correctness generalizes.** All 700 champion runs (35 runs x 20
  kernels) complete with correct results.
- **The ranking holds on the 15 unseen kernels.** The system order on the
  new-15 geomean is the held-out order: Opus 5.5 > Sonnet 5.5 >
  GPT-6.1 Sol > GPT-6 Astra > Luna > GPT-5.5. Kendall tau between runs'
  held-out and new-15 scores is 0.954. Opus 5.5 has the highest system
  geomean on all 15 new kernels.
- **The pairwise verdicts match the pre-registered ones.** Opus vs Sol is
  1.279 [1.167, 1.402] (held-out: 1.320). Opus vs Sonnet and Sol vs Astra
  are not distinguishable, as on held-out. Every other pair among the five
  systems with 6 runs separates (Holm p 0.0002 to 0.0065).
- **One contract violation the V2 gates missed.** Opus 5.5 rep6's champion
  makes an out-of-range fetch on 10 of the 15 new kernels, at addresses
  0xFFFFFF20 to 0xFFFFFFF8. Its next-fetch predictor (`fetch_pred.sv`) is
  a 64-entry, 4-bit-tag table. An aliased entry can add a negative offset
  to a PC near 0, and the wrong-path address is on `io_imemAddr` for a
  cycle before decode redirects. The results stay correct, but
  `test/cosim/main.cpp` flags any out-of-range instruction address, so the
  harness rule fails these kernels. Formal has no fetch-bounds property,
  and the harness's programs (selftest, random traces, CoreMark, held-out)
  never put that predictor state near address 0. No other champion trips
  it.
- **The harness geomean rule can reward a failure.** Under that rule
  (geomean over passing kernels), Opus rep6's new-15 geomean is 2309.1,
  higher than its 1971.0 over all 15 correct results, because the dropped
  kernels are slower ones. No scored held-out result is affected: all 34
  scored runs pass all five held-out kernels.
- **Large code penalizes the cached reference.** VexRiscv MaxPerf is 17%
  above GPT-6.1 Sol on the held-out five but level with it on the new 15.
  nsichneu (20 KB of code) and xgboost (41 KB) thrash its 8 KB instruction
  cache. The held-out kernels are small enough to fit.

V3: give the fetch port a valid signal (or add a formal bounds assertion on
`io_imemAddr`), and count a failed kernel as zero in the held-out geomean.
