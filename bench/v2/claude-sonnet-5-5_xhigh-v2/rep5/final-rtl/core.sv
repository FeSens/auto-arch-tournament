// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit drives EX-stage rs1/rs2 muxes
//   |               from EX/MEM; the MEM/WB leg is bypassed in ID (the MEM
//   |               result is captured straight into ID/EX.rs?_val)
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
  logic       ex_busy;
  logic       fwd_rs1_sel, fwd_rs2_sel;
  logic       fwd_alu_a_sel, fwd_alu_b_sel;

  // MEM -> ID late bypass (MEM/WB D inputs)
  logic [31:0] wb_fwd_data;
  logic        wb_fwd_en;

  // Registered redirect: resolved in EX, carried in EX/MEM, acted on by IF /
  // the hazard unit while the branch / jump is in MEM (flop outputs).
  logic        redirect_m;
  logic [31:0] redirect_target_m;
  assign redirect_m        = ex_mem_w.redirect;
  assign redirect_target_m = ex_mem_w.redirect_target;

  // BHT training bus: EX -> IF
  logic        bht_upd_en;
  logic [6:0]  bht_upd_idx;
  logic        bht_upd_taken;

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  // WB-stage write port: only wb_w_data (RVFI rd_wdata) is used now, the
  // regfile is written from MEM (rf_w_*).
  /* verilator lint_off UNUSEDSIGNAL */
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  // Decode-source word (FIFO head, else the live imem word) and "a word is
  // available" flag, shared by ID, the regfile read and the hazard unit.
  logic [31:0] dec_word;
  logic        word_avail;

  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .imem_ready      (io_imemReady),
    .stall_id        (stall_id),
    .flush           (flush_if),
    .redirect        (redirect_m),
    .redirect_target (redirect_target_m),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .raw_instr       (dec_word),
    .word_avail      (word_avail),
    .upd_en          (bht_upd_en),
    .upd_idx         (bht_upd_idx),
    .upd_taken       (bht_upd_taken),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .raw_instr (dec_word),
    .raw_rs1  (dec_word[19:15]),
    .raw_rs2  (dec_word[24:20]),
    .ex_mem_rd (ex_mem_w.rd),
    .wb_fwd_data (wb_fwd_data),
    .wb_fwd_en   (wb_fwd_en),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .out      (id_ex_w)
  );

  // The regfile is written from the MEM stage, i.e. with the value / enable the
  // MEM/WB register captures at this same edge (one cycle before the WB-stage
  // write). Its contents are then already up to date when the instruction is
  // in WB, so ID needs no WB-stage write-first bypass (the m2 late bypass of
  // the instruction in MEM stays in ID). Gated like the MEM/WB capture: not
  // while a dmem stall holds the instruction in MEM.
  // The regfile is LUT-RAM (async read, sync write, no reset); x0 is masked
  // on read, so writes to x0 are harmless.
  logic        rf_w_en;
  logic [4:0]  rf_w_addr;
  logic [31:0] rf_w_data;
  assign rf_w_en   = wb_fwd_en && ex_mem_w.valid && !hold_mem_wb;
  assign rf_w_addr = ex_mem_w.rd;
  assign rf_w_data = wb_fwd_data;

  reg_file #(.BYPASS(1'b0)) u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .w_en     (rf_w_en),
    .w_addr   (rf_w_addr),
    .w_data   (rf_w_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .fwd_rs1_sel     (fwd_rs1_sel),
    .fwd_rs2_sel     (fwd_rs2_sel),
    .fwd_alu_a_sel   (fwd_alu_a_sel),
    .fwd_alu_b_sel   (fwd_alu_b_sel),
    .fwd_ex_mem     (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .out             (ex_mem_w),
    .ex_busy         (ex_busy),
    .bht_upd_en      (bht_upd_en),
    .bht_upd_idx     (bht_upd_idx),
    .bht_upd_taken   (bht_upd_taken)
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
    .wb_fwd_data (wb_fwd_data),
    .wb_fwd_en   (wb_fwd_en),
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
    // Decode-source word fields (FIFO head, else live imem word; not the
    // NOP-substituted if_id_w.instr): a spurious load-use on a flushed /
    // not-delivered slot is harmless, see hazard_unit.sv.
    .if_id_rs1      (dec_word[19:15]),
    .if_id_rs2      (dec_word[24:20]),
    .redirect       (redirect_m),
    .word_avail     (word_avail),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .ex_busy        (ex_busy),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .m1_rs1      (id_ex_w.m1_rs1),
    .m1_rs2      (id_ex_w.m1_rs2),
    .m1_alu_a    (id_ex_w.m1_alu_a),
    .m1_alu_b    (id_ex_w.m1_alu_b),
    .ex_mem_w_en (ex_mem_w.ctrl.reg_write),
    .fwd_rs1     (fwd_rs1_sel),
    .fwd_rs2     (fwd_rs2_sel),
    .fwd_alu_a   (fwd_alu_a_sel),
    .fwd_alu_b   (fwd_alu_b_sel)
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
