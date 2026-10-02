# Amendment 12, step 1: tool-define branches in the final champions

Interim, written 2026-10-01 ~09:10Z with 14 of the 18 scored runs final (Opus 5.5
reps 1-6, Luna reps 1-6, GPT-6.1 Sol reps 1-2); GPT-6.1 Sol rep3 added 12:57Z, rep4
2026-10-02 02:20Z. GPT-6.1 Sol reps 5-6 are added when they finish. Found by `research/v2/scripts/tool_branches.py bench/v2` (every
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
| GPT-6.1 Sol reps 5-6 | pending | | |

So far one run needs step 2 (Opus rep2, class (b): formal on the full-size fetch store,
ceiling 6 h, after the campaign) and none has a class (c) branch, so step 3 has nothing
to recompute yet. Not part of amendment 12's scope but listed for completeness: the
unscored GPT-6 Sol pilot has no tool branch.
