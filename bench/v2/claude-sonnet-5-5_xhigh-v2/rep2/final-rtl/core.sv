// rtl/core.sv
//
// Top-level wiring for the 6-stage in-order RV32IM core.
//
//  IF -> ID -> OF -> EX -> MEM -> WB
//   |          ^ ^    |     |
//   |          | +----+     |    OF forwards the EX result (x_result, late
//   |          +-----------+     2:1 into the operand flops), the MEM result
//   |                            (m_result) and the MEM/WB wb_data flop
//   +- fetch queue (BTB-driven, runs ahead of ID); D/O / O/X hold via hazard_unit
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+5 (no hazards) or later (load-use stall,
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
  // V0 default). Drive 0 to model bus stall — the fetch pc holds and no
  // entry is queued; ID sees a NOP bubble only if the fetch queue is empty.
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
  id_ex_t  id_ex_w;      // D/O register (ID -> OF)
  ox_t     ox_w;         // O/X register (OF -> EX)
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_id, flush_id, consume;
  logic       hold_ox, bubble_ox;
  logic       stall_ex_mem, hold_mem_wb;

  // forward-out buses (EX result -> OF dist 1, MEM result -> OF dist 2)
  logic [31:0] x_result;
  logic        x_reg_write;
  logic [31:0] m_result;
  logic        m_reg_write;

  // EX mispredict redirect (registered in ex_stage: redir_q / redir_tgt_*_q)
  logic        redirect;
  logic [31:0] redirect_target;
  logic        ex_busy;

  // BTB lookup (IF) and training (EX)
  logic        btb_hit;
  logic        btb_taken;
  logic [17:0] btb_target;
  logic [1:0]  btb_ctr;
  logic        tr_en;
  logic [19:2] tr_pc;
  logic        tr_taken;
  logic        tr_is_jal;
  logic        tr_is_ret;
  logic [17:0] tr_target;
  logic        tr_hit;
  logic [1:0]  tr_ctr;
  logic        ras_push;
  logic        ras_pop;
  logic [19:2] ras_push_addr;

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
    .consume         (consume),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .pred_hit        (btb_hit),
    .pred_taken      (btb_taken),
    .pred_target     (btb_target),
    .pred_ctr        (btb_ctr),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .out             (if_id_w)
  );

  // BTB: lookup is a pure function of the fetch pc register (imem_addr);
  // training comes from EX when a direct branch / JAL advances.
  btb u_btb (
    .clock       (clock),
    .reset       (reset),
    .pc          (io_imemAddr[19:2]),
    .pred_hit    (btb_hit),
    .pred_taken  (btb_taken),
    .pred_target (btb_target),
    .pred_ctr    (btb_ctr),
    .tr_en       (tr_en),
    .tr_pc       (tr_pc),
    .tr_taken    (tr_taken),
    .tr_is_jal   (tr_is_jal),
    .tr_is_ret   (tr_is_ret),
    .tr_target   (tr_target),
    .tr_hit      (tr_hit),
    .tr_ctr      (tr_ctr),
    .ras_push    (ras_push),
    .ras_pop     (ras_pop),
    .ras_push_addr (ras_push_addr)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .out      (id_ex_w)
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

  // ── OF ────────────────────────────────────────────────────────────────
  of_stage u_of (
    .clock       (clock),
    .reset       (reset),
    .hold        (hold_ox),
    .bubble      (bubble_ox),
    .in          (id_ex_w),
    .x_result    (x_result),
    .x_reg_write (x_reg_write),
    .m_result    (m_result),
    .m_rd        (ex_mem_w.rd),
    .m_reg_write (m_reg_write),
    .w_data      (mem_wb_w.wb_data),
    .w_rd        (mem_wb_w.rd),
    .w_reg_write (mem_wb_w.ctrl.reg_write),
    .out         (ox_w)
  );

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_ex_mem),
    .in              (ox_w),
    .out             (ex_mem_w),
    .x_result        (x_result),
    .x_reg_write     (x_reg_write),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .ex_busy         (ex_busy),
    .tr_en           (tr_en),
    .tr_pc           (tr_pc),
    .tr_taken        (tr_taken),
    .tr_is_jal       (tr_is_jal),
    .tr_is_ret       (tr_is_ret),
    .tr_target       (tr_target),
    .tr_hit          (tr_hit),
    .tr_ctr          (tr_ctr),
    .ras_push        (ras_push),
    .ras_pop         (ras_pop),
    .ras_push_addr   (ras_push_addr)
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
    .m_result   (m_result),
    .m_reg_write(m_reg_write),
    .out        (mem_wb_w)
  );

  // ── WB ────────────────────────────────────────────────────────────────
  wb_stage u_wb (
    .in     (mem_wb_w),
    .w_en   (wb_w_en),
    .w_addr (wb_w_addr),
    .w_data (wb_w_data)
  );

  // ── Hazard ────────────────────────────────────────────────────────────
  hazard_unit u_hazard (
    .ox_mem_read    (ox_w.ctrl.mem_read),
    .ox_rd          (ox_w.rd),
    .do_rs1         (id_ex_w.rs1_addr),
    .do_rs2         (id_ex_w.rs2_addr),
    .head_valid     (if_id_w.valid),
    .redirect       (redirect),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .ex_busy        (ex_busy),
    .stall_id       (stall_id),
    .consume        (consume),
    .flush_id       (flush_id),
    .hold_ox        (hold_ox),
    .bubble_ox      (bubble_ox),
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
