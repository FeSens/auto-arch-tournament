// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF FIFO -> ID -> EX -> MEM -> WB
//              |     ^
//              +-----+    ID registers the EX operand selects
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 its selected writeback word.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif

module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). Drive 0 to model bus stall. IF retries the request
  // unless EX redirects, and can issue words it has already queued.
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
  // dStall holds ID/EX and EX/MEM. MEM/WB clears retirement valid and
  // holds its forwarding data until the bus delivers.
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
  logic       issue_if, stall_id, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       divide_wait, load_use;
  logic       ex_write_eligible, mem_write_eligible;
  logic [31:0] response_other_operand, load_data;
  logic [1:0]  response_equal;

  logic           repair, fence_i, train_advance, train_direct, train_taken;
  logic [31:0]    train_target;
  pc_pair_t       repair_pc;
  replay_update_t replay_update;

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
    .clock           (clock),
    .reset           (reset),
    .issue_enable    (issue_if),
    .repair          (repair),
    .repair_pc       (repair_pc),
    .fence_i         (fence_i),
    .update          (replay_update),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock              (clock),
    .reset              (reset),
    .stall              (stall_id),
    .flush              (flush_id),
    .in                 (if_id_w),
    .ex_rd              (id_ex_w.rd),
    .ex_load            (id_ex_w.valid && id_ex_w.ctrl.mem_read),
    .ex_load_word       (id_ex_w.ctrl.mem_width == 2'd2),
    .ex_write_eligible  (ex_write_eligible),
    .ex_result_sel      (id_ex_w.result_sel),
    .mem_rd             (ex_mem_w.rd),
    .mem_may_write      (ex_mem_w.ctrl.reg_write),
    .mem_write_eligible (mem_write_eligible),
    .load_use           (load_use),
    .rs1_addr           (rs1_addr_w),
    .rs2_addr           (rs2_addr_w),
    .rs1_data           (rs1_data_w),
    .rs2_data           (rs2_data_w),
    .out                (id_ex_w)
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
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (id_ex_w),
    .fwd_mem_wb      (mem_wb_w.write_data),
    .load_response   (io_dmemREn),
    .raw_response    (io_dmemRData),
    .load_data       (load_data),
    .response_equal  (response_equal),
    .response_other_operand (response_other_operand),
    .out             (ex_mem_w),
    .write_eligible  (ex_write_eligible),
    .divide_wait     (divide_wait),
    .repair          (repair),
    .repair_pc       (repair_pc),
    .fence_i         (fence_i),
    .train_advance   (train_advance),
    .train_direct    (train_direct),
    .train_taken     (train_taken),
    .train_target    (train_target)
  );

  replay_train u_replay_train (
    .clock   (clock),
    .reset   (reset),
    .fence_i (fence_i),
    .advance (train_advance),
    .pc      (ex_mem_w.pc),
    .pc_next (train_target),
    .instr   (ex_mem_w.instr),
    .direct  (train_direct),
    .taken   (train_taken),
    .update  (replay_update)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock          (clock),
    .reset          (reset),
    .hold_wb        (hold_mem_wb),
    .in             (ex_mem_w),
    .dmem_addr      (io_dmemAddr),
    .dmem_wdata     (io_dmemWData),
    .dmem_rdata     (io_dmemRData),
    .dmem_wen      (io_dmemWEn),
    .dmem_ren      (io_dmemREn),
    .write_eligible (mem_write_eligible),
    .response_other_operand (response_other_operand),
    .response_equal (response_equal),
    .load_data      (load_data),
    .out            (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazards ───────────────────────────────────────────────────────────
  hazard_unit u_hazard (
    .load_use       (load_use),
    .repair         (repair),
    .divide_wait    (divide_wait),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .issue_if       (issue_if),
    .stall_id       (stall_id),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
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
