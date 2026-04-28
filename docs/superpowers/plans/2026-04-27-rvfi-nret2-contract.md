# RVFI NRET=2 Contract Bump Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Widen the RVFI port set on `core` from a single retirement channel (NRET=1) to two channels (NRET=2) so future hypotheses can explore superscalar dual-issue without changing the verification contract per-hypothesis. The current single-issue pipeline ties channel 1 off; tests must produce the same results as before.

**Architecture:** Per-channel split ports — every `io_rvfi_<field>` becomes `io_rvfi_<field>_0` and `io_rvfi_<field>_1` of the same width as the scalar predecessor. Channel 0 carries the older retirement (or the only one in single-issue cycles); channel 1 the younger. The contract change is mechanical and must land as one coherent commit because intermediate states don't compile (rename cascades through `rtl/core.sv`, `formal/wrapper.sv`, `formal/checks.cfg`, `fpga/core_bench.sv`, `test/cosim/main.cpp`, `test/test_pipeline.py`, plus `CLAUDE.md`).

**Tech Stack:** SystemVerilog, riscv-formal, cocotb, Verilator, sby/bitwuzla, yosys.

---

## File Structure

| File | Why it changes |
|------|----------------|
| `rtl/core.sv` | Top-level port shape rename + channel-1 tie-off |
| `formal/wrapper.sv` | Wire 2-channel `RVFI_OUTPUTS` macro to per-channel ports |
| `formal/checks.cfg` | `nret 1` → `nret 2` |
| `fpga/core_bench.sv` | Wires every RVFI port; rename to `_0`, add `_1` |
| `test/cosim/main.cpp` | Sample channel 0 then channel 1 per cycle |
| `test/test_pipeline.py` | Cocotb probes by signal name; rename to `_0` |
| `CLAUDE.md` | Invariant 1 + invariant 4 + "must not" list amendments |

`formal/riscv-formal/cores/auto-arch-researcher/*.sv` is staged from `rtl/*.sv` + `formal/wrapper.sv` by `formal/run_all.sh` on every formal run — no manual edit.

`test/cosim/vex_main.cpp` wraps `VVexRiscv` (their core), not ours — no change.

---

## Task 1: Capture baseline test results

**Files:**
- Create: `docs/superpowers/plans/baseline-pre-nret2.txt` (working artifact, deleted on commit)

- [ ] **Step 1: Verify clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean` (or only the new plan file untracked)

- [ ] **Step 2: Run lint and capture**

Run: `make lint 2>&1 | tee /tmp/baseline-lint.txt`
Expected: clean exit (no errors). Save the output for comparison.

- [ ] **Step 3: Run cocotb suite and capture**

Run: `make test 2>&1 | tee /tmp/baseline-test.txt`
Expected: pytest summary line ending in `passed` for the full suite. Capture the final summary line (e.g. `===== N passed in M.MMs =====`).

- [ ] **Step 4: Run cosim and capture**

Run: `make cosim 2>&1 | tee /tmp/baseline-cosim.txt`
Expected: cosim eval prints a summary; final line indicates pass. Capture the summary line(s) — these are the values to match after the rename.

- [ ] **Step 5: Run formal fast suite and capture**

Run: `make formal 2>&1 | tee /tmp/baseline-formal.txt`
Expected: `Formal: N passed, 0 failed` (final line). Capture N — must match exactly after rename.

- [ ] **Step 6: Pin the pass counts**

Read each baseline file's tail and record:
  - Lint: pass/fail
  - Cocotb: number passed
  - Cosim: pass/fail + any cycle counts
  - Formal: number of passing checks (e.g. "Formal: 8 passed, 0 failed")

These are the numbers Task 8 must match. **Do not proceed if any baseline test fails — fix the underlying issue first.**

---

## Task 2: Rename RVFI ports to channel 0 + add channel 1 tie-off in `rtl/core.sv`

**Files:**
- Modify: `rtl/core.sv:53-72` (port declarations)
- Modify: `rtl/core.sv:217-241` (RVFI driver `always_comb` block)

- [ ] **Step 1: Replace the RVFI port declarations**

Replace lines 52-72 (the `// RVFI` comment + 21 scalar output declarations) with:

```systemverilog
  // RVFI — 2-channel retirement port set (NRET=2 contract).
  // Channel 0: older / sole retirement; channel 1: younger.
  // Single-issue cores tie channel 1 off (rvfi_valid_1=0, others='0).
  // See CLAUDE.md invariant 1 for the full contract.
  output logic        io_rvfi_valid_0,
  output logic [63:0] io_rvfi_order_0,
  output logic [31:0] io_rvfi_insn_0,
  output logic        io_rvfi_trap_0,
  output logic        io_rvfi_halt_0,
  output logic        io_rvfi_intr_0,
  output logic [1:0]  io_rvfi_mode_0,
  output logic [1:0]  io_rvfi_ixl_0,
  output logic [4:0]  io_rvfi_rs1_addr_0,
  output logic [31:0] io_rvfi_rs1_rdata_0,
  output logic [4:0]  io_rvfi_rs2_addr_0,
  output logic [31:0] io_rvfi_rs2_rdata_0,
  output logic [4:0]  io_rvfi_rd_addr_0,
  output logic [31:0] io_rvfi_rd_wdata_0,
  output logic [31:0] io_rvfi_pc_rdata_0,
  output logic [31:0] io_rvfi_pc_wdata_0,
  output logic [31:0] io_rvfi_mem_addr_0,
  output logic [3:0]  io_rvfi_mem_rmask_0,
  output logic [3:0]  io_rvfi_mem_wmask_0,
  output logic [31:0] io_rvfi_mem_rdata_0,
  output logic [31:0] io_rvfi_mem_wdata_0,
  output logic        io_rvfi_valid_1,
  output logic [63:0] io_rvfi_order_1,
  output logic [31:0] io_rvfi_insn_1,
  output logic        io_rvfi_trap_1,
  output logic        io_rvfi_halt_1,
  output logic        io_rvfi_intr_1,
  output logic [1:0]  io_rvfi_mode_1,
  output logic [1:0]  io_rvfi_ixl_1,
  output logic [4:0]  io_rvfi_rs1_addr_1,
  output logic [31:0] io_rvfi_rs1_rdata_1,
  output logic [4:0]  io_rvfi_rs2_addr_1,
  output logic [31:0] io_rvfi_rs2_rdata_1,
  output logic [4:0]  io_rvfi_rd_addr_1,
  output logic [31:0] io_rvfi_rd_wdata_1,
  output logic [31:0] io_rvfi_pc_rdata_1,
  output logic [31:0] io_rvfi_pc_wdata_1,
  output logic [31:0] io_rvfi_mem_addr_1,
  output logic [3:0]  io_rvfi_mem_rmask_1,
  output logic [3:0]  io_rvfi_mem_wmask_1,
  output logic [31:0] io_rvfi_mem_rdata_1,
  output logic [31:0] io_rvfi_mem_wdata_1
```

- [ ] **Step 2: Update the RVFI driver `always_comb` block**

In the `always_comb` block at ~line 219, rename every `io_rvfi_<field>` to `io_rvfi_<field>_0` and add the channel-1 tie-off block. Replace the contents of the block with:

```systemverilog
  always_comb begin
    // Channel 0: the only retirement channel for the single-issue baseline.
    io_rvfi_valid_0     = mem_wb_w.valid;
    io_rvfi_order_0     = rvfi_order_q;
    io_rvfi_insn_0      = mem_wb_w.instr;
    io_rvfi_trap_0      = mem_wb_w.ctrl.is_illegal;
    io_rvfi_halt_0      = 1'b0;
    io_rvfi_intr_0      = 1'b0;
    io_rvfi_mode_0      = 2'd3;
    io_rvfi_ixl_0       = 2'd1;
    io_rvfi_rs1_addr_0  = mem_wb_w.rs1_addr;
    io_rvfi_rs1_rdata_0 = mem_wb_w.rs1_val;
    io_rvfi_rs2_addr_0  = mem_wb_w.rs2_addr;
    io_rvfi_rs2_rdata_0 = mem_wb_w.rs2_val;
    io_rvfi_rd_addr_0   = rd_wen ? mem_wb_w.rd : 5'b0;
    io_rvfi_rd_wdata_0  = rd_wen ? wb_w_data   : 32'b0;
    io_rvfi_pc_rdata_0  = mem_wb_w.pc;
    io_rvfi_pc_wdata_0  = mem_wb_w.pc_next;
    io_rvfi_mem_addr_0  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask_0 = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask_0 = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata_0 = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata_0 = mem_wb_w.mem_wdata;

    // Channel 1: tied off — V0 is single-issue. valid=0 is the canonical
    // "this channel is unused" signature; other fields driven to '0 to
    // avoid X/Z propagation through the formal harness.
    io_rvfi_valid_1     = 1'b0;
    io_rvfi_order_1     = 64'b0;
    io_rvfi_insn_1      = 32'b0;
    io_rvfi_trap_1      = 1'b0;
    io_rvfi_halt_1      = 1'b0;
    io_rvfi_intr_1      = 1'b0;
    io_rvfi_mode_1      = 2'b0;
    io_rvfi_ixl_1       = 2'b0;
    io_rvfi_rs1_addr_1  = 5'b0;
    io_rvfi_rs1_rdata_1 = 32'b0;
    io_rvfi_rs2_addr_1  = 5'b0;
    io_rvfi_rs2_rdata_1 = 32'b0;
    io_rvfi_rd_addr_1   = 5'b0;
    io_rvfi_rd_wdata_1  = 32'b0;
    io_rvfi_pc_rdata_1  = 32'b0;
    io_rvfi_pc_wdata_1  = 32'b0;
    io_rvfi_mem_addr_1  = 32'b0;
    io_rvfi_mem_rmask_1 = 4'b0;
    io_rvfi_mem_wmask_1 = 4'b0;
    io_rvfi_mem_rdata_1 = 32'b0;
    io_rvfi_mem_wdata_1 = 32'b0;
  end
```

- [ ] **Step 3: Verify rtl/ lints cleanly**

Run: `make lint 2>&1 | head -60`
Expected: clean exit. `make lint` only lints `rtl/*.sv`, so the wrapper/bench/cosim files (still using old names) won't show up here yet — they're checked in Task 8.

(If lint fails, an internal rtl/ file references the old `io_rvfi_*` names. Investigate before proceeding.)

---

## Task 3: Update `formal/wrapper.sv` to wire 2-channel RVFI macro

**Files:**
- Modify: `formal/wrapper.sv:55-75` (RVFI port connections in `core uut (...)` block)

- [ ] **Step 1: Rewrite the RVFI port connections**

Replace lines 55-75 (the `.io_rvfi_<field>(rvfi_<field>)` connections inside the `core uut (...)` instantiation) with:

```systemverilog
        // Channel 0 — low NRET slice of each RVFI bus.
        .io_rvfi_valid_0    (rvfi_valid    [0]),
        .io_rvfi_order_0    (rvfi_order    [63:0]),
        .io_rvfi_insn_0     (rvfi_insn     [31:0]),
        .io_rvfi_trap_0     (rvfi_trap     [0]),
        .io_rvfi_halt_0     (rvfi_halt     [0]),
        .io_rvfi_intr_0     (rvfi_intr     [0]),
        .io_rvfi_mode_0     (rvfi_mode     [1:0]),
        .io_rvfi_ixl_0      (rvfi_ixl      [1:0]),
        .io_rvfi_rs1_addr_0 (rvfi_rs1_addr [4:0]),
        .io_rvfi_rs1_rdata_0(rvfi_rs1_rdata[31:0]),
        .io_rvfi_rs2_addr_0 (rvfi_rs2_addr [4:0]),
        .io_rvfi_rs2_rdata_0(rvfi_rs2_rdata[31:0]),
        .io_rvfi_rd_addr_0  (rvfi_rd_addr  [4:0]),
        .io_rvfi_rd_wdata_0 (rvfi_rd_wdata [31:0]),
        .io_rvfi_pc_rdata_0 (rvfi_pc_rdata [31:0]),
        .io_rvfi_pc_wdata_0 (rvfi_pc_wdata [31:0]),
        .io_rvfi_mem_addr_0 (rvfi_mem_addr [31:0]),
        .io_rvfi_mem_rmask_0(rvfi_mem_rmask[3:0]),
        .io_rvfi_mem_wmask_0(rvfi_mem_wmask[3:0]),
        .io_rvfi_mem_rdata_0(rvfi_mem_rdata[31:0]),
        .io_rvfi_mem_wdata_0(rvfi_mem_wdata[31:0]),
        // Channel 1 — high NRET slice. riscv-formal packs higher channels
        // in higher bit ranges: rvfi_<field>[NRET*W-1:W] for ch 1.
        .io_rvfi_valid_1    (rvfi_valid    [1]),
        .io_rvfi_order_1    (rvfi_order    [127:64]),
        .io_rvfi_insn_1     (rvfi_insn     [63:32]),
        .io_rvfi_trap_1     (rvfi_trap     [1]),
        .io_rvfi_halt_1     (rvfi_halt     [1]),
        .io_rvfi_intr_1     (rvfi_intr     [1]),
        .io_rvfi_mode_1     (rvfi_mode     [3:2]),
        .io_rvfi_ixl_1      (rvfi_ixl      [3:2]),
        .io_rvfi_rs1_addr_1 (rvfi_rs1_addr [9:5]),
        .io_rvfi_rs1_rdata_1(rvfi_rs1_rdata[63:32]),
        .io_rvfi_rs2_addr_1 (rvfi_rs2_addr [9:5]),
        .io_rvfi_rs2_rdata_1(rvfi_rs2_rdata[63:32]),
        .io_rvfi_rd_addr_1  (rvfi_rd_addr  [9:5]),
        .io_rvfi_rd_wdata_1 (rvfi_rd_wdata [63:32]),
        .io_rvfi_pc_rdata_1 (rvfi_pc_rdata [63:32]),
        .io_rvfi_pc_wdata_1 (rvfi_pc_wdata [63:32]),
        .io_rvfi_mem_addr_1 (rvfi_mem_addr [63:32]),
        .io_rvfi_mem_rmask_1(rvfi_mem_rmask[7:4]),
        .io_rvfi_mem_wmask_1(rvfi_mem_wmask[7:4]),
        .io_rvfi_mem_rdata_1(rvfi_mem_rdata[63:32]),
        .io_rvfi_mem_wdata_1(rvfi_mem_wdata[63:32])
```

(The wrapper module header still uses `\`RVFI_OUTPUTS`, which expands to wider buses once `nret 2` is set in checks.cfg in Task 4. The bit slices above match the macro's packing — channel 0 in the low bits, channel 1 in the high bits.)

---

## Task 4: Bump `formal/checks.cfg` to NRET=2

**Files:**
- Modify: `formal/checks.cfg:3`

- [ ] **Step 1: Change `nret 1` to `nret 2`**

Replace the line `nret 1` with `nret 2`. Leave every other line in the file unchanged. The `[verilog-files]` section is auto-rebuilt by `formal/run_all.sh` from `rtl/*.sv` + `formal/wrapper.sv` so no edits there.

---

## Task 5: Update `fpga/core_bench.sv` RVFI wiring

**Files:**
- Modify: `fpga/core_bench.sv:55-101` (RVFI logic decls + `core` instantiation)
- Modify: `fpga/core_bench.sv:107-` (the XOR-reduce LED expression that consumes every RVFI signal)

- [ ] **Step 1: Read the current state of the file**

Run: `wc -l fpga/core_bench.sv` and read the file in full to know the exact line ranges.

- [ ] **Step 2: Rename every `rvfi_<field>` local logic + `core` connection to `rvfi_<field>_0`, then add channel-1 logic and connections**

For each of the 21 RVFI fields:
- Rename the local `logic` declaration `rvfi_<field>` → `rvfi_<field>_0` (and its width unchanged).
- Add a parallel local `logic` declaration `rvfi_<field>_1` of the same width.
- Rename the connection in `core uut(...)` from `.io_rvfi_<field>(rvfi_<field>)` → `.io_rvfi_<field>_0(rvfi_<field>_0)`.
- Add a parallel `.io_rvfi_<field>_1(rvfi_<field>_1)` connection.

Concretely, the new declaration block (replacing lines 55-63) is:

```systemverilog
  logic        rvfi_valid_0, rvfi_valid_1;
  logic [63:0] rvfi_order_0, rvfi_order_1;
  logic [31:0] rvfi_insn_0, rvfi_pc_rdata_0, rvfi_pc_wdata_0;
  logic [31:0] rvfi_insn_1, rvfi_pc_rdata_1, rvfi_pc_wdata_1;
  logic [31:0] rvfi_rd_wdata_0, rvfi_rs1_rdata_0, rvfi_rs2_rdata_0;
  logic [31:0] rvfi_rd_wdata_1, rvfi_rs1_rdata_1, rvfi_rs2_rdata_1;
  logic [31:0] rvfi_mem_addr_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0;
  logic [31:0] rvfi_mem_addr_1, rvfi_mem_rdata_1, rvfi_mem_wdata_1;
  logic [4:0]  rvfi_rs1_addr_0, rvfi_rs2_addr_0, rvfi_rd_addr_0;
  logic [4:0]  rvfi_rs1_addr_1, rvfi_rs2_addr_1, rvfi_rd_addr_1;
  logic [3:0]  rvfi_mem_rmask_0, rvfi_mem_wmask_0;
  logic [3:0]  rvfi_mem_rmask_1, rvfi_mem_wmask_1;
  logic [1:0]  rvfi_mode_0, rvfi_ixl_0;
  logic [1:0]  rvfi_mode_1, rvfi_ixl_1;
  logic        rvfi_trap_0, rvfi_halt_0, rvfi_intr_0;
  logic        rvfi_trap_1, rvfi_halt_1, rvfi_intr_1;
```

The new RVFI connection block (replacing lines 80-100) is:

```systemverilog
    .io_rvfi_valid_0    (rvfi_valid_0),
    .io_rvfi_order_0    (rvfi_order_0),
    .io_rvfi_insn_0     (rvfi_insn_0),
    .io_rvfi_trap_0     (rvfi_trap_0),
    .io_rvfi_halt_0     (rvfi_halt_0),
    .io_rvfi_intr_0     (rvfi_intr_0),
    .io_rvfi_mode_0     (rvfi_mode_0),
    .io_rvfi_ixl_0      (rvfi_ixl_0),
    .io_rvfi_rs1_addr_0 (rvfi_rs1_addr_0),
    .io_rvfi_rs1_rdata_0(rvfi_rs1_rdata_0),
    .io_rvfi_rs2_addr_0 (rvfi_rs2_addr_0),
    .io_rvfi_rs2_rdata_0(rvfi_rs2_rdata_0),
    .io_rvfi_rd_addr_0  (rvfi_rd_addr_0),
    .io_rvfi_rd_wdata_0 (rvfi_rd_wdata_0),
    .io_rvfi_pc_rdata_0 (rvfi_pc_rdata_0),
    .io_rvfi_pc_wdata_0 (rvfi_pc_wdata_0),
    .io_rvfi_mem_addr_0 (rvfi_mem_addr_0),
    .io_rvfi_mem_rmask_0(rvfi_mem_rmask_0),
    .io_rvfi_mem_wmask_0(rvfi_mem_wmask_0),
    .io_rvfi_mem_rdata_0(rvfi_mem_rdata_0),
    .io_rvfi_mem_wdata_0(rvfi_mem_wdata_0),
    .io_rvfi_valid_1    (rvfi_valid_1),
    .io_rvfi_order_1    (rvfi_order_1),
    .io_rvfi_insn_1     (rvfi_insn_1),
    .io_rvfi_trap_1     (rvfi_trap_1),
    .io_rvfi_halt_1     (rvfi_halt_1),
    .io_rvfi_intr_1     (rvfi_intr_1),
    .io_rvfi_mode_1     (rvfi_mode_1),
    .io_rvfi_ixl_1      (rvfi_ixl_1),
    .io_rvfi_rs1_addr_1 (rvfi_rs1_addr_1),
    .io_rvfi_rs1_rdata_1(rvfi_rs1_rdata_1),
    .io_rvfi_rs2_addr_1 (rvfi_rs2_addr_1),
    .io_rvfi_rs2_rdata_1(rvfi_rs2_rdata_1),
    .io_rvfi_rd_addr_1  (rvfi_rd_addr_1),
    .io_rvfi_rd_wdata_1 (rvfi_rd_wdata_1),
    .io_rvfi_pc_rdata_1 (rvfi_pc_rdata_1),
    .io_rvfi_pc_wdata_1 (rvfi_pc_wdata_1),
    .io_rvfi_mem_addr_1 (rvfi_mem_addr_1),
    .io_rvfi_mem_rmask_1(rvfi_mem_rmask_1),
    .io_rvfi_mem_wmask_1(rvfi_mem_wmask_1),
    .io_rvfi_mem_rdata_1(rvfi_mem_rdata_1),
    .io_rvfi_mem_wdata_1(rvfi_mem_wdata_1)
```

- [ ] **Step 3: Update the XOR-reduce LED expression to include both channels**

Find the `assign led = ^{...}` expression starting around line 107 and replace its operand list to include both channels. The new expression:

```systemverilog
  assign led = ^{rvfi_valid_0, rvfi_order_0, rvfi_insn_0, rvfi_trap_0, rvfi_halt_0, rvfi_intr_0,
                 rvfi_mode_0, rvfi_ixl_0, rvfi_rs1_addr_0, rvfi_rs1_rdata_0,
                 rvfi_rs2_addr_0, rvfi_rs2_rdata_0, rvfi_rd_addr_0, rvfi_rd_wdata_0,
                 rvfi_pc_rdata_0, rvfi_pc_wdata_0, rvfi_mem_addr_0, rvfi_mem_rmask_0,
                 rvfi_mem_wmask_0, rvfi_mem_rdata_0, rvfi_mem_wdata_0,
                 rvfi_valid_1, rvfi_order_1, rvfi_insn_1, rvfi_trap_1, rvfi_halt_1, rvfi_intr_1,
                 rvfi_mode_1, rvfi_ixl_1, rvfi_rs1_addr_1, rvfi_rs1_rdata_1,
                 rvfi_rs2_addr_1, rvfi_rs2_rdata_1, rvfi_rd_addr_1, rvfi_rd_wdata_1,
                 rvfi_pc_rdata_1, rvfi_pc_wdata_1, rvfi_mem_addr_1, rvfi_mem_rmask_1,
                 rvfi_mem_wmask_1, rvfi_mem_rdata_1, rvfi_mem_wdata_1};
```

(If the original expression spans multiple lines beyond 107, read those lines and replace the full expression. Channel-1 wires are constants in V0 so synthesis will eliminate them — harmless to include.)

---

## Task 6: Update `test/cosim/main.cpp` to drain channel 0 then channel 1

**Files:**
- Modify: `test/cosim/main.cpp:179-209` (the per-cycle RVFI sample + JSON emit block)

- [ ] **Step 1: Refactor the RVFI sample block into a per-channel helper macro**

Replace lines 179-209 with code that samples channel 0 first, then channel 1. JSON output format is unchanged (one line per retirement, identical field names) so downstream consumers (run_cosim.py, reference.py, tools/eval/cosim.py) need no changes.

```cpp
        auto emit_retirement = [&](int ch,
                                   uint8_t  v,
                                   uint64_t order,
                                   uint32_t insn,
                                   uint32_t pc_rdata, uint32_t pc_wdata,
                                   uint8_t  rd_addr,  uint32_t rd_wdata,
                                   uint8_t  rs1_addr, uint32_t rs1_rdata,
                                   uint8_t  rs2_addr, uint32_t rs2_rdata,
                                   uint32_t mem_addr,
                                   uint8_t  mem_rmask, uint32_t mem_rdata,
                                   uint8_t  mem_wmask, uint32_t mem_wdata,
                                   uint8_t  trap, uint8_t halt, uint8_t intr,
                                   uint8_t  mode, uint8_t ixl) -> bool {
            (void)ch;
            if (!v) return false;
            char buf[640];
            snprintf(buf, sizeof(buf),
                "{\"order\":%llu,\"cycle\":%llu,\"insn\":%u,\"pc_rdata\":%u,\"pc_wdata\":%u,"
                "\"rd_addr\":%u,\"rd_wdata\":%u,"
                "\"rs1_addr\":%u,\"rs1_rdata\":%u,"
                "\"rs2_addr\":%u,\"rs2_rdata\":%u,"
                "\"mem_addr\":%u,\"mem_rmask\":%u,\"mem_rdata\":%u,"
                "\"mem_wmask\":%u,\"mem_wdata\":%u,"
                "\"trap\":%u,\"halt\":%u,\"intr\":%u,\"mode\":%u,\"ixl\":%u}",
                (unsigned long long)order,
                (unsigned long long)cycle,
                insn, pc_rdata, pc_wdata,
                rd_addr, rd_wdata,
                rs1_addr, rs1_rdata,
                rs2_addr, rs2_rdata,
                mem_addr, mem_rmask, mem_rdata,
                mem_wmask, mem_wdata,
                (unsigned)trap, (unsigned)halt, (unsigned)intr,
                (unsigned)mode, (unsigned)ixl);
            if (bench_mode) {
                strncpy(bench_last, buf, sizeof(bench_last)-1);
                if (insn == 0x00100073) { hit_ebreak = true; return true; }
            } else {
                puts(buf);
                fflush(stdout);
                if (insn == 0x00100073) { hit_ebreak = true; return true; }
            }
            return false;
        };

        // Channel 0 first (older retirement), then channel 1 — preserves
        // rvfi_order monotonicity in the JSON stream for reference.py.
        bool ebreak0 = emit_retirement(0,
            top->io_rvfi_valid_0, top->io_rvfi_order_0, top->io_rvfi_insn_0,
            top->io_rvfi_pc_rdata_0, top->io_rvfi_pc_wdata_0,
            top->io_rvfi_rd_addr_0, top->io_rvfi_rd_wdata_0,
            top->io_rvfi_rs1_addr_0, top->io_rvfi_rs1_rdata_0,
            top->io_rvfi_rs2_addr_0, top->io_rvfi_rs2_rdata_0,
            top->io_rvfi_mem_addr_0,
            top->io_rvfi_mem_rmask_0, top->io_rvfi_mem_rdata_0,
            top->io_rvfi_mem_wmask_0, top->io_rvfi_mem_wdata_0,
            top->io_rvfi_trap_0, top->io_rvfi_halt_0, top->io_rvfi_intr_0,
            top->io_rvfi_mode_0, top->io_rvfi_ixl_0);
        if (ebreak0) break;
        bool ebreak1 = emit_retirement(1,
            top->io_rvfi_valid_1, top->io_rvfi_order_1, top->io_rvfi_insn_1,
            top->io_rvfi_pc_rdata_1, top->io_rvfi_pc_wdata_1,
            top->io_rvfi_rd_addr_1, top->io_rvfi_rd_wdata_1,
            top->io_rvfi_rs1_addr_1, top->io_rvfi_rs1_rdata_1,
            top->io_rvfi_rs2_addr_1, top->io_rvfi_rs2_rdata_1,
            top->io_rvfi_mem_addr_1,
            top->io_rvfi_mem_rmask_1, top->io_rvfi_mem_rdata_1,
            top->io_rvfi_mem_wmask_1, top->io_rvfi_mem_wdata_1,
            top->io_rvfi_trap_1, top->io_rvfi_halt_1, top->io_rvfi_intr_1,
            top->io_rvfi_mode_1, top->io_rvfi_ixl_1);
        if (ebreak1) break;
```

For V0 (single-issue), `io_rvfi_valid_1` is always 0, so the second `emit_retirement` always returns false and the JSON output stream is byte-identical to the pre-rename baseline. This is the key invariant Task 8 verifies.

---

## Task 7: Update `test/test_pipeline.py` cocotb probes to channel 0 names

**Files:**
- Modify: `test/test_pipeline.py:107-139`

- [ ] **Step 1: Rename every `dut.io_rvfi_<field>` reference to `dut.io_rvfi_<field>_0`**

The cocotb `Pipeline` test pulls scalar RVFI signals at lines 107-139. For V0 (single-issue), only channel 0 retires, so renaming all references to `_0` preserves test behavior exactly. Replace:

```python
        rvfi_v    = int(dut.io_rvfi_valid.value)
```

with:

```python
        rvfi_v    = int(dut.io_rvfi_valid_0.value)
```

…and the same `_0` suffix on each of:
- `dut.io_rvfi_order` → `dut.io_rvfi_order_0`
- `dut.io_rvfi_insn` → `dut.io_rvfi_insn_0`
- `dut.io_rvfi_pc_rdata` → `dut.io_rvfi_pc_rdata_0`
- `dut.io_rvfi_pc_wdata` → `dut.io_rvfi_pc_wdata_0`
- `dut.io_rvfi_rd_addr` → `dut.io_rvfi_rd_addr_0`
- `dut.io_rvfi_rd_wdata` → `dut.io_rvfi_rd_wdata_0`
- `dut.io_rvfi_rs1_addr` → `dut.io_rvfi_rs1_addr_0`
- `dut.io_rvfi_rs1_rdata` → `dut.io_rvfi_rs1_rdata_0`
- `dut.io_rvfi_rs2_addr` → `dut.io_rvfi_rs2_addr_0`
- `dut.io_rvfi_rs2_rdata` → `dut.io_rvfi_rs2_rdata_0`
- `dut.io_rvfi_trap` → `dut.io_rvfi_trap_0`
- `dut.io_rvfi_mem_addr` → `dut.io_rvfi_mem_addr_0`
- `dut.io_rvfi_mem_wmask` → `dut.io_rvfi_mem_wmask_0`
- `dut.io_rvfi_mem_wdata` → `dut.io_rvfi_mem_wdata_0`
- `dut.io_rvfi_mem_rmask` → `dut.io_rvfi_mem_rmask_0`
- `dut.io_rvfi_mem_rdata` → `dut.io_rvfi_mem_rdata_0`

- [ ] **Step 2: Sanity-grep that no bare `io_rvfi_*` (without `_0`/`_1`) remains anywhere in test/**

Run: `grep -rn 'io_rvfi_[a-z_]*\b' test/ | grep -v '_0\b' | grep -v '_1\b'`
Expected: empty output. Any hits are leftover references that will fail.

---

## Task 8: Run all tests and compare to baseline

**Files:** none modified — verification only.

- [ ] **Step 1: Run lint**

Run: `make lint 2>&1 | tee /tmp/post-lint.txt`
Expected: clean exit. Diff is allowed: zero new warnings/errors compared to baseline.

- [ ] **Step 2: Run cocotb suite**

Run: `make test 2>&1 | tee /tmp/post-test.txt`
Expected: same number of passing tests as baseline (`make test` baseline number from Task 1 step 3). No new failures.

- [ ] **Step 3: Run cosim**

Run: `make cosim 2>&1 | tee /tmp/post-cosim.txt`
Expected: same pass/fail status and same cycle counts as baseline. Since channel 1 is always invalid in V0, the JSON retirement stream from the cosim binary is byte-identical to baseline — any divergence is a bug to investigate.

- [ ] **Step 4: Run formal fast suite**

Run: `make formal 2>&1 | tee /tmp/post-formal.txt`
Expected: same pass count as baseline (e.g. `Formal: 8 passed, 0 failed` if baseline showed 8). The framework now runs at NRET=2 — every check generalizes correctly: `unique` validates orders are contiguous across channels (with channel 1 always invalid, it reduces to single-channel monotonicity); `pc_fwd`/`pc_bwd`/`causal`/`liveness`/`ill` likewise.

- [ ] **Step 5: Compare baselines side-by-side**

Compare each pair of files:
- `/tmp/baseline-lint.txt` vs `/tmp/post-lint.txt`
- `/tmp/baseline-test.txt` vs `/tmp/post-test.txt`
- `/tmp/baseline-cosim.txt` vs `/tmp/post-cosim.txt`
- `/tmp/baseline-formal.txt` vs `/tmp/post-formal.txt`

For each: confirm pass/fail status matches and pass counts match. Cosim summary numbers must match exactly.

If anything diverges, **stop and investigate** before proceeding to CLAUDE.md amendment. Do NOT weaken the baseline by editing tests to mask a regression.

---

## Task 9: Amend `CLAUDE.md` with the NRET=2 contract

**Files:**
- Modify: `CLAUDE.md` (invariant table rows 1 and 4; "What hypotheses MAY change" "must not" block; new "Working notes" subsection)

- [ ] **Step 1: Replace invariant 1 row in the table**

Find the row:
```
| 1 | Top module `core` exposes the RVFI port set (32 signals, exact names)                                      | cocotb smoke test, `riscv-formal` wrapper    |
```

Replace with:
```
| 1 | Top module `core` exposes a 2-channel RVFI port set: every `io_rvfi_<field>` has `_0` and `_1` variants of the same width as its scalar predecessor. Channel 0 carries the older of two simultaneous retirements; channel 1 the younger. Single-retire cycles MUST place the retirement on channel 0 with `io_rvfi_valid_1 = 0`. All channel-1 ports MUST be driven (no X/Z); tie unused fields to '0. | cocotb smoke test, `riscv-formal` wrapper at NRET=2 |
```

- [ ] **Step 2: Replace invariant 4 row**

Find:
```
| 4 | `rvfi_order` strictly monotonic +1 per retirement (no double-retire)                                       | `riscv-formal unique` check                  |
```

Replace with:
```
| 4 | `rvfi_order` strictly monotonic +1 per retirement across both channels combined (no gaps, no duplicates). When both channels retire in the same cycle, channel-0 order = N and channel-1 order = N+1. | `riscv-formal unique` check |
```

- [ ] **Step 3: Update the "must not" first bullet under "What hypotheses MAY change"**

Find:
```
- Change `core`'s top-level IO shape.
```

Replace with:
```
- Change `core`'s top-level IO shape — specifically: the imem/dmem port set, and the **2-channel** RVFI port set with field naming `io_rvfi_<field>_<n>` for n ∈ {0,1}, channel-0-older convention, and the single-retire-on-channel-0 rule.
```

- [ ] **Step 4: Update the paragraph under "What hypotheses MAY change" that lists the IO contract**

Find the paragraph beginning:
```
The only top-level invariant on `rtl/core.sv` is that it exposes a port
named `core` whose IO matches the RVFI wrapper's expectations
(`io_imemAddr`, `io_imemData`, `io_dmemAddr`, `io_dmemRData`, `io_dmemWData`,
`io_dmemWEn`, `io_dmemREn`, all `io_rvfi_*` fields, `clock`, `reset`).
```

Replace `all io_rvfi_*` with `all io_rvfi_*_0 and io_rvfi_*_1` (NRET=2 channels):

```
The only top-level invariant on `rtl/core.sv` is that it exposes a port
named `core` whose IO matches the RVFI wrapper's expectations
(`io_imemAddr`, `io_imemData`, `io_imemReady`, `io_dmemAddr`, `io_dmemRData`,
`io_dmemWData`, `io_dmemWEn`, `io_dmemREn`, `io_dmemReady`, all
`io_rvfi_*_0` and `io_rvfi_*_1` fields, `clock`, `reset`).
```

- [ ] **Step 5: Append a new subsection at the end of "Working notes"**

Add at the bottom of the "Working notes" section, before the file ends:

```markdown
### Superscalar / NRET=2 contract

The RVFI port set is fixed at NRET=2 to permit dual-issue hypotheses without
contract churn. Single-issue cores tie channel 1 off (`io_rvfi_valid_1 = 0`
plus the rest of channel 1's fields driven to '0) — about 21 lines of
`assign io_rvfi_*_1 = '0;`. Triple-issue or wider would be a future
contract bump (NRET=K), not a per-hypothesis decision.

The contract change touches: `rtl/core.sv` (port set), `formal/wrapper.sv`
(macro packing), `formal/checks.cfg` (`nret 2`), `fpga/core_bench.sv`
(bench wiring), `test/cosim/main.cpp` (per-channel drain), and
`test/test_pipeline.py` (cocotb probes use `_0` suffix for V0).
```

---

## Task 10: Commit the contract bump

**Files:** all touched in Tasks 2–9.

- [ ] **Step 1: Verify working tree**

Run: `git status`
Expected: modifications to `rtl/core.sv`, `formal/wrapper.sv`, `formal/checks.cfg`, `fpga/core_bench.sv`, `test/cosim/main.cpp`, `test/test_pipeline.py`, `CLAUDE.md`. Plus the new `docs/superpowers/plans/2026-04-27-rvfi-nret2-contract.md`.

- [ ] **Step 2: Stage explicitly (not `-A`)**

Run:
```bash
git add rtl/core.sv formal/wrapper.sv formal/checks.cfg fpga/core_bench.sv \
        test/cosim/main.cpp test/test_pipeline.py CLAUDE.md \
        docs/superpowers/plans/2026-04-27-rvfi-nret2-contract.md
```

- [ ] **Step 3: Commit with a single coherent message**

Run:
```bash
git commit -m "$(cat <<'EOF'
contract: widen RVFI to NRET=2 for superscalar exploration

Bumps the core's top-level RVFI port set from a single retirement channel
to two channels (io_rvfi_<field>_0 and io_rvfi_<field>_1). Single-issue
hypotheses tie channel 1 off; future dual-issue hypotheses can wire both
channels. Tests produce identical results — channel 1 is invalid in V0
so cosim JSON output and formal pass count are unchanged.
EOF
)"
```

- [ ] **Step 4: Verify commit landed and tree is clean**

Run: `git status && git log -1 --stat`
Expected: clean tree; commit shows the 7 files modified plus the plan added.

---

## Notes on what this plan does NOT cover

- **`make formal-deep`**: not part of the per-iteration suite; not run as a baseline. The deep run is slow (hours) and is run periodically. No NRET=2-specific change is needed there beyond what `formal/checks.cfg` already implies (the deep cfg also gets `nret 2` if it's separate — verify in `formal/checks-deep.cfg`). If `checks-deep.cfg` exists, audit it for `nret 1` and update consistently.
- **`make fpga`**: not run as a baseline because it requires nextpnr P&R (slow). Yosys synth is implicitly exercised by the cosim build (Verilator) and by formal (Yosys via sby). After the contract bump the user can run `make fpga` separately to confirm full FPGA pipeline still works, but it's not gating for the contract change.
- **Hypothesis prompt updates** (telling agents about NRET=2): out of scope here. Once the contract lands, `tools/orchestrator` and `docs/bootstrap-prompt.md` should be updated separately to mention the dual-channel option to hypotheses.
