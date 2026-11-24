// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit drives EX-stage rs1/rs2 muxes
//   |               from EX/MEM and MEM/WB
//   +- stall <- hazard_unit (load-use replay, divider wait and bus stalls)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+4 (no hazards) or later (bus stall,
//                 redirect, divide/remainder).
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 its registered writeback value.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM.
  // With the bus unready, IF can accept a word from target replay.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall — when there is a memory op in EX/MEM, the entire pipeline
  // freezes back to MEM. MEM/WB clears retirement validity and retains
  // its forwarding value until the bus delivers.
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
  logic        fetch_accept, hold_id;
  logic        stall_ex_mem, hold_mem_wb;
  logic        div_wait, load_replay, replay_consumer;
  logic [1:0]  replay_load_match;
  logic [31:0] replay_rs1, replay_rs2;
  fwd_sel_t    fwd_rs1_sel, fwd_rs2_sel;
  logic        mem_request, mem_write_en;
  logic [31:0] fwd_load_rs1, fwd_load_rs2;
  logic        mem_load_word, load_address_rs1;
  logic [31:0] load_address_data;

  // Registered EX resolution and predictor training
  fetch_resolution_t fetch_resolution;
  logic              squash_candidate;
  logic              fetch_parked;
  logic [31:0]       ordinary_pc;
  logic [31:0]       candidate_pc;
  logic              candidate_btb_hit;
  logic [1:0]        candidate_btb_counter;
  logic [31:0]       pc_next;
  logic              control_misalign;
  btb_training_t     btb_training;
  logic              training_taken;
  btb_update_t       btb_update;

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock            (clock),
    .reset            (reset),
    .hold_id          (hold_id),
    .hold_mem         (stall_ex_mem),
    .fetch_resolution (fetch_resolution),
    .btb_training     (btb_training),
    .training_taken   (training_taken),
    .candidate_pc     (candidate_pc),
    .candidate_btb_hit(candidate_btb_hit),
    .candidate_btb_counter(candidate_btb_counter),
    .btb_update       (btb_update),
    .squash_candidate (squash_candidate),
    .imem_addr        (io_imemAddr),
    .imem_data        (io_imemData),
    .imem_ready       (io_imemReady),
    .fetch_accept     (fetch_accept),
    .ordinary_pc      (ordinary_pc),
    .fetch_parked     (fetch_parked),
    .out              (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock            (clock),
    .reset            (reset),
    .hold             (hold_id),
    .fetch_accept     (fetch_accept),
    .squash_candidate (squash_candidate),
    .replay_consumer  (replay_consumer),
    .replay_load_match(replay_load_match),
    .replay_rs1       (replay_rs1),
    .replay_rs2       (replay_rs2),
    .candidate_pc     (candidate_pc),
    .candidate_btb_hit(candidate_btb_hit),
    .candidate_btb_counter(candidate_btb_counter),
    .btb_update       (btb_update),
    .in               (if_id_w),
    .ex_rd            (id_ex_w.rd),
    .mem_rd           (ex_mem_w.rd),
    .rs1_addr         (rs1_addr_w),
    .rs2_addr         (rs2_addr_w),
    .rs1_data         (rs1_data_w),
    .rs2_data         (rs2_data_w),
    .out              (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
    .reset    (reset),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .w_en     (wb_w_en),
    .w_addr   (wb_w_addr),
    .w_data   (wb_w_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock            (clock),
    .reset            (reset),
    .stall            (stall_ex_mem),
    .squash_candidate (squash_candidate),
    .in               (id_ex_w),
    .fetch_pc         (ordinary_pc),
    .fetch_parked     (fetch_parked),
    .fwd_rs1_sel      (fwd_rs1_sel),
    .fwd_rs2_sel      (fwd_rs2_sel),
    .fwd_other        (ex_mem_w.other_result),
    .fwd_add          (ex_mem_w.add_result),
    .fwd_shift        (ex_mem_w.shift_result),
    .fwd_div          (ex_mem_w.div_result),
    .fwd_mul          (ex_mem_w.mul_result),
    .fwd_load_rs1     (fwd_load_rs1),
    .fwd_load_rs2     (fwd_load_rs2),
    .load_address_data(load_address_data),
    .mem_load_word    (mem_load_word),
    .fwd_mem_wb       (wb_w_data),
    .out              (ex_mem_w),
    .div_wait         (div_wait),
    .load_replay      (load_replay),
    .replay_consumer  (replay_consumer),
    .replay_load_match(replay_load_match),
    .replay_rs1       (replay_rs1),
    .replay_rs2       (replay_rs2),
    .fetch_resolution (fetch_resolution),
    .btb_training     (btb_training),
    .training_taken   (training_taken),
    .pc_next          (pc_next),
    .control_misalign (control_misalign)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock         (clock),
    .reset         (reset),
    .hold_wb       (hold_mem_wb),
    .pc_next       (pc_next),
    .control_misalign(control_misalign),
    .in            (ex_mem_w),
    .dmem_addr     (io_dmemAddr),
    .dmem_wdata    (io_dmemWData),
    .dmem_rdata    (io_dmemRData),
    .dmem_ready    (io_dmemReady),
    .dmem_wen      (io_dmemWEn),
    .dmem_ren      (io_dmemREn),
    .mem_request   (mem_request),
    .write_en      (mem_write_en),
    .load_rs1      (fwd_rs1_sel.result.load),
    .load_rs2      (fwd_rs2_sel.result.load),
    .load_address_rs1(load_address_rs1),
    .load_word     (mem_load_word),
    .load_address_data(load_address_data),
    .load_data_rs1 (fwd_load_rs1),
    .load_data_rs2 (fwd_load_rs2),
    .out           (mem_wb_w)
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
    .div_wait       (div_wait),
    .load_replay    (load_replay),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (mem_request),
    .hold_id        (hold_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  assign load_address_rs1 = id_ex_w.ctrl.mem_read && fwd_rs1_sel.result.load;

  forward_unit u_fwd (
    .ex_match    (id_ex_w.ex_match),
    .mem_match   (id_ex_w.mem_match),
    .ex_mem_w_en (mem_write_en),
    .ex_mem_sel  (ex_mem_w.result_sel),
    .mem_wb_w_en (mem_wb_w.reg_write),
    .fwd_rs1     (fwd_rs1_sel),
    .fwd_rs2     (fwd_rs2_sel)
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
    rd_wen = wb_w_en && (mem_wb_w.rd != 5'b0);

    // Channel 0: the only retirement channel for the single-issue baseline.
    io_rvfi_valid_0     = mem_wb_w.valid;
    io_rvfi_order_0     = rvfi_order_q;
    io_rvfi_insn_0      = mem_wb_w.instr;
    io_rvfi_trap_0      = mem_wb_w.trap;
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
