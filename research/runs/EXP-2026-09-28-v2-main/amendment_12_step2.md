# Amendment 12, step 2: formal on the synthesized arm

Run 2026-10-04 10:04Z to 10:27Z on hwe-bench, after the campaign ended (10:03Z), per
amendment 12's step 2: "for each champion with a (b) branch: run the harness's formal checks
(formal/run_all.sh, the core's checks config, same depth) on the RTL with the formal-only
branch replaced by the simulation/synthesis one, ceiling 6 h". Step 1 (amendment_12_step1.md)
found two such champions across all 36 scored runs: Opus 5.5 rep2 (main) and Sonnet 5.5 rep5
(extension).

Runner: `research/v2/scripts/amendment12_step2.py`. Each case gets its own tree under
`~/a12step2/<case>`: the fixture at `bench-v2.8.2` (`git archive`, so nothing is written into
the repository), a copy of the riscv-formal checkout the clones copy, and the run's
`final-rtl/` as `cores/bench/rtl`. The patch keeps only the `else arm of the class (b) branch.
Every other line, including the class (a) branches, is the champion's. Formal is the fixture's
`formal/run_all.sh` with `wrapper_si.sv` and `checks_si.cfg` (the nret=1 invocation of
`tools/eval/formal.py`, same depth). A control runs each unpatched champion the same way, to
check that the tree reproduces the harness's verdict. Results, patches and full logs are in
`amendment_12_step2/<case>/`.

| run | formal-only branch replaced | checks | verdict | wall time | slowest check |
|---|---|---|---|---|---|
| Opus 5.5 rep2 (control, unpatched) | none | 53 of 53 pass | pass | 345 s | reg_ch0 338 s |
| Opus 5.5 rep2 | if_stage.sv FS_IDX_W: 9 (512 entries per bank, the simulated and synthesized size) instead of 1 under RISCV_FORMAL | 53 of 53 pass | **pass** | 372 s | reg_ch0 347 s |
| Sonnet 5.5 rep5 (control, unpatched) | none | 53 of 53 pass | pass | 136 s | reg_ch0 37 s |
| Sonnet 5.5 rep5 | reg_file.sv: the RAM16SDP4-style 16x4 slices (two copies, one per read port) instead of 32 flop words under RISCV_FORMAL | 53 of 53 pass | **pass** | 1,378 s | reg_ch0 1,374 s |

Checked that the patched RTL reached formal: the staged Opus `if_stage.sv` has
`FS_IDX_W = 9` and yosys elaborated `fetch_store` with `IDX_W = 9`. The staged Sonnet
`reg_file.sv` has no RISCV_FORMAL arm and its model contains the slice memories.

The four runs shared the host (JOBS 4 for the controls, 6 for the patched runs). The wall
times are therefore upper bounds. Both patched runs would also have finished inside the
harness's own 2,700 s ceiling.

## Outcome

Both class (b) champions pass the full formal suite on the design that simulation and synthesis
build. No run fails step 2, and step 1 found no class (c) branch, so step 3 has nothing to
recompute. The primary test and the amendment 13 family, repeated without runs that fail step 2
or have a score-relevant (c) branch, are the pre-registered ones unchanged (n = 6 for every
system; analysis_final.md).

Finding 01 stands as a contract gap (formal did not see the scored RTL), and the V3 item stays:
reject tool-define branches other than RISCV_FORMAL_ALTOPS, or require identical parameters
across the formal, simulation and synthesis builds. For these two champions the gap did not
hide a bug. Opus rep2's formal-only shrink was not needed for time (372 s against 345 s); Sonnet
rep5's flop model cut the `reg` check from 1,374 s to 37 s.
