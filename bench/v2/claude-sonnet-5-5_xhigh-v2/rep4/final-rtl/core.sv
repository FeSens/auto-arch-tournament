// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    ^     |  |
//   |    +-----+--+    forward_unit (on the raw fetched rs fields) drives
//   |                  the ID-stage bypass mux that feeds the ID/EX
//   |                  capture: EX result (P1) and MEM result (P2); the
//   |                  regfile is written from MEM, so it already holds the
//   |                  WB-stage result when ID reads it
//   +- stall <- hazard_unit (load-use)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+4 (no hazards) or later (load-use stall,
//                 redirect).
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 the WB-stage write-data mux (RVFI only; the regfile
//                 write port is fed from MEM).
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). Drive 0 to model bus stall — PC reg holds, IF/ID
  // payload becomes a NOP, and a pipeline bubble propagates downstream.
  // Used by test/cosim/vex_main.cpp's --istall mode to match VexRiscv's
  // random ~22% backpressure model so CoreMark/MHz can be compared
  // apples-to-apples with their published "full no cache" number.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall — when there is a memory op in EX/MEM, the entire pipeline
  // freezes back to MEM; MEM/WB captures a bubble; the LOAD/STORE waits
  // until the bus delivers.
  input  logic        io_dmemReady,
  // RVFI — single-channel retirement port set (NRET=1 contract,
  // declared via `nret: 1` in core.yaml). Channel 0 is the sole
  // retirement channel. See CLAUDE.md invariant 1 for the full contract.
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
  output logic [31:0] io_rvfi_mem_wdata_0
);

  // ── Inter-stage wires ──────────────────────────────────────────────────
  if_id_t  if_id_w;
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_id, flush_if, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       div_stall;

  // ID-stage bypass network
  logic [31:0] ex_res, mem_res;
  logic        ex_res_en, mem_res_en;
  logic        p1_hit_rs1, p2_hit_rs1, p1_hit_rs2, p2_hit_rs2;

  // Registered recovery: EX resolves a mispredict / JALR, EX/MEM captures a
  // 1-bit redir; the PC mux, fetch queue, IF NOP mask, ID/EX flush and the EX
  // squash are all driven from that flop (target = EX/MEM.pc_next).
  logic        redirect;
  logic [31:0] redirect_target;
  assign redirect        = ex_mem_w.redir;
  assign redirect_target = ex_mem_w.pc_next;

  // regfile interface (read addresses from the unmasked fetch-queue head,
  // write port from MEM: the instruction in MEM writes its result at the end
  // of the cycle in which it leaves MEM, i.e. one cycle before it is in WB)
  logic [4:0]  head_rs1_w;
  logic [4:0]  head_rs2_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        rf_w_en;
  logic [4:0]  rf_w_addr;
  logic [31:0] rf_w_data;
  // WB-stage retirement write data (RVFI only)
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .flush           (flush_if),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .stall_id        (stall_id),
    .head_rs1        (head_rs1_w),
    .head_rs2        (head_rs2_w),
    // BHT training from the registered EX/MEM stage (off the redirect cone)
    .bht_upd_en      (ex_mem_w.valid & ex_mem_w.ctrl.is_branch),
    .bht_upd_idx     (ex_mem_w.pc[8:2]),
    .bht_upd_taken   (ex_mem_w.branch_taken),
    .bht_upd_bwd     (ex_mem_w.bwd),
    // I-cache fill from the registered ID/EX flops
    .wr_valid        (id_ex_w.valid),
    .wr_pc           (id_ex_w.pc[19:2]),
    .wr_instr        (id_ex_w.instr),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .ex_res     (ex_res),
    .mem_res    (mem_res),
    .p1_hit_rs1 (p1_hit_rs1),
    .p2_hit_rs1 (p2_hit_rs1),
    .p1_hit_rs2 (p1_hit_rs2),
    .p2_hit_rs2 (p2_hit_rs2),
    .out      (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (head_rs1_w),
    .rs2_addr (head_rs2_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .w_en     (rf_w_en),
    .w_addr   (rf_w_addr),
    .w_data   (rf_w_data)
  );

  // Regfile write port, driven from MEM. rd != 0 is already folded into
  // mem_res_en (via ctrl.reg_write), so x0 is never written. A dmem-stalled
  // load/store in MEM does not write (stall_ex_mem): it writes in the cycle
  // the bus delivers, which is also the cycle it moves to MEM/WB, so there is
  // exactly one write per instruction. An instruction in WB in cycle t was
  // therefore written at the end of cycle t-1 and the instruction in ID in
  // cycle t reads it from the regfile (no WB / P3 bypass needed).
  assign rf_w_en   = mem_res_en && ex_mem_w.valid && !stall_ex_mem;
  assign rf_w_addr = ex_mem_w.rd;
  assign rf_w_data = mem_res;

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .out             (ex_mem_w),
    .div_stall       (div_stall),
    .redirect        (redirect),
    .ex_res          (ex_res),
    .ex_res_en       (ex_res_en)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .mem_res    (mem_res),
    .mem_res_en (mem_res_en),
    .out        (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  // RVFI retirement write data only (the regfile is written from MEM).
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  hazard_unit u_hazard (
    .id_ex_late_res (id_ex_w.ctrl.late_res),
    .id_ex_rd       (id_ex_w.rd),
    // Load-use is checked against the UNMASKED fetch-queue head (flop-selected
    // e0 vs imem_data), not the NOP-gated if_id_w.instr: gating on redirect
    // would put the whole EX redirect cone in front of this compare. It is
    // equivalent: on redirect EX holds a branch/jump (late_res = 0, so no
    // load-use), and a spurious hit on a non-present head only turns the
    // already-invalid bubble into a stall/flush of an invalid slot.
    .if_id_rs1      (head_rs1_w),
    .if_id_rs2      (head_rs2_w),
    .redirect       (redirect),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .div_stall      (div_stall),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  // ID-side bypass selects. Compared on the unmasked head rs fields (like
  // the load-use check and the regfile read addresses), not the NOP-masked
  // if_id_w.instr: a stale select on a flushed / invalid ID bubble is
  // harmless (ID/EX is cleared on redirect and a NOP's operands are never
  // observed), and it keeps the late `redirect` out of the select cone.
  forward_unit u_fwd (
    .rs1        (head_rs1_w),
    .rs2        (head_rs2_w),
    .ex_rd      (id_ex_w.rd),
    .ex_res_en  (ex_res_en),
    .mem_rd     (ex_mem_w.rd),
    .mem_res_en (mem_res_en),
    .p1_hit_rs1 (p1_hit_rs1),
    .p2_hit_rs1 (p2_hit_rs1),
    .p1_hit_rs2 (p1_hit_rs2),
    .p2_hit_rs2 (p2_hit_rs2)
  );

  // ── RVFI ──────────────────────────────────────────────────────────────
  // The MEM/WB register is the retirement boundary. rvfi_order increments
  // every cycle rvfi_valid is high; CLAUDE.md invariant 4 (riscv-formal
  // unique-check) requires strict +1.
  logic [63:0] rvfi_order_q;
  logic        rd_wen;

  always_ff @(posedge clock) begin
    if (reset)                rvfi_order_q <= 64'b0;
    else if (mem_wb_w.valid)  rvfi_order_q <= rvfi_order_q + 64'b1;
  end

  always_comb begin
    // reg_write already has rd != 0 folded in (id_stage), and is cleared on a
    // misalign trap.
    rd_wen = mem_wb_w.ctrl.reg_write;

    // Channel 0: the only retirement channel for the single-issue baseline.
    io_rvfi_valid_0     = mem_wb_w.valid;
    io_rvfi_order_0     = rvfi_order_q;
    io_rvfi_insn_0      = mem_wb_w.instr;
    io_rvfi_trap_0      = mem_wb_w.ctrl.is_illegal;
    io_rvfi_halt_0      = 1'b0;
    io_rvfi_intr_0      = 1'b0;
    io_rvfi_mode_0      = 2'd3;     // M-mode only
    io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA
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
  end

endmodule
