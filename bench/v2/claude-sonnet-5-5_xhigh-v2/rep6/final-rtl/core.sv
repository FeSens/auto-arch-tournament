// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit resolves the bypass selects in ID; ID
//   |               captures the MEM-stage result into ID/EX, EX only
//   |               forwards from EX/MEM
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
//                 the WB-stage write-data mux.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). Drive 0 to model bus stall — a fetch that misses the I-cache
  // becomes an invalid F/D slot and a pipeline bubble propagates downstream.
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
  logic       stall_if, stall_id, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       mdu_stall;
  logic [1:0] fwd_rs1_sel;
  logic       sel1_ex, sel1_wb, sel2_ex, sel2_wb;

  // result of the instruction in MEM (about to enter MEM/WB), captured by ID
  logic [31:0] wb_next;
  logic        wb_next_ok;

  // EX mispredict recovery (registered in ex_stage) and BHT update
  logic        kill;
  logic [31:0] kill_target;
  logic        bht_upd_valid;
  logic [7:0]  bht_upd_idx;
  logic        bht_upd_taken;
  logic [1:0]  bht_upd_cnt;

  // regfile interface (driven by ID + WB stages). The read addresses are the
  // F/D instruction flop bits (like the hazard unit's): a bubble slot carries
  // a garbage instruction with fd_valid = 0 (id_stage zeroes its ctrl), so
  // the operands read for it are never used, and nothing from the fetch loop
  // (cache hit, imem_ready) reaches the regfile read and forward-select
  // cones. A garbage slot may add a spurious load-use stall (performance
  // only).
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  assign rs1_addr_w = if_id_w.instr[19:15];
  assign rs2_addr_w = if_id_w.instr[24:20];
  logic [31:0] rs1_data_w;
  logic [31:0] rs1_raw_w;
  logic [31:0] rs2_raw_w;
  logic        rs1_byp_w;
  logic        rs2_byp_w;
  // reg_file's bypassed rs2 read is superseded by rs2_raw/rs2_byp in ID.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] rs2_data_w;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .hold            (stall_if),
    .kill            (kill),
    .kill_target     (kill_target),
    .imem_ready      (io_imemReady),
    .bht_upd_valid   (bht_upd_valid),
    .bht_upd_idx     (bht_upd_idx),
    .bht_upd_taken   (bht_upd_taken),
    .bht_upd_cnt     (bht_upd_cnt),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
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
    .rs1_raw  (rs1_raw_w),
    .rs2_raw  (rs2_raw_w),
    .rs1_byp  (rs1_byp_w),
    .rs2_byp  (rs2_byp_w),
    .wb_data  (wb_w_data),
    .sel1_ex  (sel1_ex),
    .sel1_wb  (sel1_wb),
    .sel2_ex  (sel2_ex),
    .sel2_wb  (sel2_wb),
    .wb_next  (wb_next),
    .out      (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .rs1_raw  (rs1_raw_w),
    .rs2_raw  (rs2_raw_w),
    .rs1_byp  (rs1_byp_w),
    .rs2_byp  (rs2_byp_w),
    .w_en     (wb_w_en),
    .w_addr   (wb_w_addr),
    .w_data   (wb_w_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .fwd_rs1_sel     (fwd_rs1_sel),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // MEM/WB write data (RVFI rs1 only)
    .out             (ex_mem_w),
    .kill            (kill),
    .kill_target     (kill_target),
    .bht_upd_valid   (bht_upd_valid),
    .bht_upd_idx     (bht_upd_idx),
    .bht_upd_taken   (bht_upd_taken),
    .bht_upd_cnt     (bht_upd_cnt),
    .mdu_stall       (mdu_stall)
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
    .wb_next    (wb_next),
    .wb_next_ok (wb_next_ok),
    .out        (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard / forwarding ───────────────────────────────────────────────
  hazard_unit u_hazard (
    .id_ex_mem_read (id_ex_w.ctrl.mem_read),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (rs1_addr_w),           // F/D instruction flop bits
    .if_id_rs2      (rs2_addr_w),
    .kill           (kill),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .mdu_stall      (mdu_stall),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .if_id_rs1   (rs1_addr_w),             // ID-stage select generation
    .if_id_rs2   (rs2_addr_w),
    .id_ex_rd    (id_ex_w.rd),
    .id_ex_w_en  (id_ex_w.ctrl.reg_write),
    .sel1_ex     (sel1_ex),
    .sel1_wb     (sel1_wb),
    .sel2_ex     (sel2_ex),
    .sel2_wb     (sel2_wb),
    .ex_mem_rd   (ex_mem_w.rd),
    .wb_next_ok  (wb_next_ok),
    .ex_mem_w_en (ex_mem_w.ctrl.reg_write),
    .id_ex_rs1   (id_ex_w.rs1_addr),       // RVFI-only EX-stage compare
    .mem_wb_rd   (mem_wb_w.rd),
    .mem_wb_w_en (mem_wb_w.ctrl.reg_write),
    .fwd_rs1     (fwd_rs1_sel)
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
    rd_wen = mem_wb_w.ctrl.reg_write && (mem_wb_w.rd != 5'b0);

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
