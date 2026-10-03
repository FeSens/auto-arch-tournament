# Amendment 12, step 1: tool-define branches in the final champions

Interim, written 2026-10-01 ~09:10Z with 14 of the 18 scored runs final (Opus 5.5
reps 1-6, Luna reps 1-6, GPT-6.1 Sol reps 1-2); GPT-6.1 Sol rep3 added 12:57Z, rep4
2026-10-02 02:20Z, rep5 16:35Z. GPT-6.1 Sol rep6 2026-10-03 03:28Z (all 18 main runs final). Found by `research/v2/scripts/tool_branches.py bench/v2` (every
`ifdef/`ifndef/`elsif other than RISCV_FORMAL_ALTOPS and include guards, including
`ifndef X / `include package guards), then classified by reading each branch.

Classes (amendment 12): (a) state before the CoreMark start marker only, (b) formal-only
structure or parameter change, (c) simulated and synthesized behavior differ after the
start marker, (d) other.

| run | branch | what it does | class |
|---|---|---|---|
| Opus rep1 | none | | |
| Opus rep2 | if_stage.sv:41 `ifdef RISCV_FORMAL / elsif FORMAL | fetch store index width FS_IDX_W: 2 entries per bank under formal, 512 in simulation and synthesis (amendment 12 finding 01) | (b) |
| Opus rep2 | fetch_store.sv:80 (VERILATOR / RISCV_FORMAL / FORMAL) and :88, :188 (FETCH_STORE_RESET) | simulation and formal reset the fetch store; synthesis clears it with a post-reset sweep | (a) |
| Opus rep2 | reg_file.sv:43 (VERILATOR / RISCV_FORMAL / FORMAL) and :51 (REG_FILE_RESET) | simulation and formal reset the register file; synthesis leaves it unreset | (a) |
| Opus rep3 | if_stage.sv:59 `ifdef VERILATOR | zero-initializes the 16-entry BTB memory in simulation only; formal starts from arbitrary contents and the BTB only steers prediction (Gowin distributed RAM powers up zero) | (a) |
| Opus rep4 | reg_file.sv:41 `ifdef VERILATOR | the register file is reset in simulation only; formal and synthesis leave it unreset | (a) |
| Opus rep5 | none | | |
| Opus rep6 | none | | |
| Luna reps 1-6 | none (reps 3-5: `ifndef CORE_PKG_DEFINED / `include package guards only) | | |
| GPT-6.1 Sol reps 1-2 | none (`ifndef CORE_PKG_DEFINED / `include package guards only) | | |
| GPT-6.1 Sol rep3 | if_stage.sv:151 `ifdef RISCV_FORMAL (8 lines; plus the `ifndef CORE_PKG_DEFINED package guard) | two immediate assertions on its fetch queue (`occupancy_q <= 2`, and no live redirect masked while recovery is pending) and no logic; riscv-formal's `chformal -early` keeps DUT assertions as extra proof obligations, so formal proves more than simulation and synthesis check and no behavior differs by tool | (d) |
| GPT-6.1 Sol rep4 | none (`ifndef CORE_PKG_DEFINED / `include package guards only) | | |
| GPT-6.1 Sol rep5 | none (`ifndef CORE_PKG_DEFINED / `include package guards only) | | |
| GPT-6.1 Sol rep6 | none | | |

Final for the 18 main runs: one run needs step 2 (Opus rep2, class (b): formal on the
full-size fetch store, ceiling 6 h, after the campaign) and none has a class (c) branch,
so step 3 has nothing to recompute. Not part of amendment 12's scope but listed for completeness: the
unscored GPT-6 Sol pilot has no tool branch.

## Extension runs (amendment 13)

Amendment 12's scope is the 18 main runs; amendment 13 does not mention it. Written
2026-10-03 ~00:05Z, before the first extension champion with a class (b) candidate
(Sonnet 5.5 rep5) has a results row: the same three steps are applied to every extension
run's final champion and reported in this separate table, with the same rules (the
extension verdicts stay the amendment 13 ones; the extension family is repeated with runs
whose champion fails step 2 or has a score-relevant (c) branch removed, n reported).

| run | branch | what it does | class |
|---|---|---|---|
| GPT-6 Astra rep1 | none | | |
| GPT-6 Astra rep2 | if_stage.sv:39 `ifdef YOSYS | the 4-entry fetch FIFO is `logic [65:0] entries [0:3]` under Yosys and `if_id_t entries [0:3]` otherwise; if_id_t is a 66-bit packed struct and every access is a whole entry, so both arms are bit-identical (the comment says Yosys drops the unpacked dimension of the struct typedef) | (d) |
| GPT-6 Astra rep3 | none | | |
| GPT-6 Astra rep4 | none | | |
| Sonnet 5.5 reps 1-4 | none | | |
| Sonnet 5.5 rep5 | reg_file.sv:61 `ifdef RISCV_FORMAL (final champion r9s1, row 2026-10-03 00:02Z) | the register file is 32 flop words under formal and two copies of 16x4 RAM16SDP4 slices (one per read port) in simulation and synthesis; same async read, sync write, no reset, half split and x0 mask, so formal proves a different structure of the same function. The header gives the reason (the slices' SMT arrays made the `reg` check take over 6 min per check). Operator's bounded equivalence of the two arms at 20:53Z (yosys miter, zero initial contents, 8 steps): equal; the final file is byte-identical to the checked one | (b) |
| Sonnet 5.5 rep6 | none (final champion r14s1, row 2026-10-03 08:54Z; `ifndef CORE_PKG_DEFINED package guard only) | | |

Extension runs needing step 2 so far: Sonnet 5.5 rep5 (formal on the RAM16SDP4 register
file, ceiling 6 h, after the campaign, with Opus rep2's). Sonnet 5.5 is final (6 of 6): rep5
is its only step 2 run and none of its champions has a class (c) branch.
