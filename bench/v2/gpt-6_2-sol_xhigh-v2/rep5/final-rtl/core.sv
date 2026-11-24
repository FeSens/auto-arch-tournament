// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF/decode -> issue FIFO -> ID -> EX -> MEM -> WB
//                              ID preselects the source of each EX operand.
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
//                 redirect, divide, bus stall).
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 the registered writeback value.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // A stalled imem response cannot enter the issue FIFO. Queued packets
  // can still issue and EX can redirect the request.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall — when there is a memory op in EX/MEM, issue and execute hold
  // and MEM/WB captures a bubble. Fetch can fill the FIFO while waiting.
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
  issue_packet_t if_id_w;
  id_ex_t  id_ex_q, id_ex_w;
  ex_mem_t ex_mem_q, ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       issue_candidate, issue, stall_issue, hold_id_ex;
  logic       stall_ex_mem, hold_mem_wb;
  logic       divide_wait;
  logic [31:0] multiply_result, divide_result;
  logic       ex_fast_write, mem_next_write;
  logic       pending_rs1, pending_rs2;
  operand_sel_t rs1_sel, rs2_sel;

  logic        ex_redirect, mem_redirect, ex_recovery, mem_recovery, advance_aperture;
  logic [31:2] ex_redirect_word, mem_redirect_word;
  logic        ex_train, ex_taken, mem_train, mem_taken;
  logic [5:0]  ex_index, mem_index;

  // Mask the younger stages during the corrected request. With a MEM
  // miss, the instruction that was in EX cannot reach the data bus.
  always_comb begin
    id_ex_w = id_ex_q;
    id_ex_w.valid = id_ex_q.valid && !(ex_recovery || mem_recovery);
    ex_mem_w = ex_mem_q;
    ex_mem_w.valid = ex_mem_q.valid && !mem_recovery;
  end

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        rs1_nonzero, rs2_nonzero;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .issue_stall     (stall_issue),
    .imem_ready      (io_imemReady),
    .ex_redirect     (ex_redirect),
    .ex_redirect_word(ex_redirect_word),
    .mem_redirect    (mem_redirect),
    .mem_redirect_word(mem_redirect_word),
    .ex_recovery     (ex_recovery),
    .mem_recovery    (mem_recovery),
    .advance_aperture (advance_aperture),
    .train_branch    (mem_train || ex_train),
    .train_index     (mem_train ? mem_index : ex_index),
    .train_taken     (mem_train ? mem_taken : ex_taken),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .issue_candidate (issue_candidate),
    .issue           (issue),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .hold     (hold_id_ex),
    .issue_candidate (issue_candidate),
    .issue    (issue),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .rs1_sel  (rs1_sel),
    .rs2_sel  (rs2_sel),
    .pending_rs1 (pending_rs1),
    .pending_rs2 (pending_rs2),
    .out      (id_ex_q)
  );

  reg_file u_rf (
    .clock       (clock),
    .reset       (reset),
    .rs1_addr    (rs1_addr_w),
    .rs2_addr    (rs2_addr_w),
    .rs1_data    (rs1_data_w),
    .rs2_data    (rs2_data_w),
    .rs1_nonzero (rs1_nonzero),
    .rs2_nonzero (rs2_nonzero),
    .w_en        (wb_w_en),
    .w_addr      (wb_w_addr),
    .w_data      (wb_w_data)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .mem_recovery    (mem_recovery),
    .in              (id_ex_w),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // MEM/WB-registered result
    .mem_next_write  (mem_next_write),
    .out             (ex_mem_q),
    .fast_write      (ex_fast_write),
    .multiply_result (multiply_result),
    .divide_result   (divide_result),
    .divide_wait     (divide_wait),
    .advance_aperture (advance_aperture),
    .redirect        (ex_redirect),
    .redirect_word   (ex_redirect_word),
    .train_branch    (ex_train),
    .train_index     (ex_index),
    .train_taken     (ex_taken)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .recovery   (mem_recovery),
    .in         (ex_mem_w),
    .multiply_result (multiply_result),
    .divide_result   (divide_result),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .next_write (mem_next_write),
    .redirect   (mem_redirect),
    .redirect_word(mem_redirect_word),
    .train_branch(mem_train),
    .train_index(mem_index),
    .train_taken(mem_taken),
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
    .id_ex_late_result (id_ex_w.valid && (id_ex_w.ctrl.mem_read ||
                                         id_ex_w.ctrl.is_mul || id_ex_w.ctrl.is_div ||
                                         id_ex_w.late_add)),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (rs1_addr_w),
    .if_id_rs2      (rs2_addr_w),
    .late_eligible  (if_id_w.late_eligible),
    .divide_wait    (divide_wait),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.valid && (ex_mem_w.ctrl.mem_read || ex_mem_w.ctrl.mem_write)),
    .pending_rs1    (pending_rs1),
    .pending_rs2    (pending_rs2),
    .stall_issue    (stall_issue),
    .hold_id_ex     (hold_id_ex),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .rs1_addr      (rs1_addr_w),
    .rs2_addr      (rs2_addr_w),
    .rs1_nonzero   (rs1_nonzero),
    .rs2_nonzero   (rs2_nonzero),
    .ex_rd         (id_ex_w.rd),
    .ex_fast_write (ex_fast_write),
    .mem_rd        (ex_mem_w.rd),
    .mem_write     (mem_next_write),
    .rs1_sel       (rs1_sel),
    .rs2_sel       (rs2_sel)
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
