// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
// IF -> ID -> EX -> MEM -> WB. Decode registers the forwarding selects
// for EX. The hazard unit handles late-result dependencies, division,
// and bus stalls.
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        full pipeline; instruction n retires at MEM/WB on
//                 cycle n+4 (no hazards) or later (dependency stall,
//                 redirect).
// RVFI fields:    all of them — driven from the MEM/WB register.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif

module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // A stalled request can advance from replay when the queue has space.
  input  logic        io_imemReady,
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // dmem bus backpressure. Drive 1 for zero-wait. Drive 0 to model
  // dStall holds a memory op in EX/MEM and stalls decode. MEM/WB clears
  // its retirement valid bit while fetch can still fill the queue.
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
  id_ex_t  ex_in;
  ex_mem_t ex_mem_w;
  ex_mem_t mem_in;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       decode_accept, stall_id, flush_id, late_dependency;
  logic       stall_ex_mem, dmem_pending, div_wait;
  logic       ex_fast_write, mem_wb_reg_write;
  fetch_hazard_t fetch_hazard;
  load_match_t load_match;
  operand_sel_t rs1_sel, rs2_sel;
  logic [31:0] load_data;

  logic        correction_q, correction_mem_q, invalidate_replay_q;
  logic        ex_redirect, mem_redirect, fence_refetch;
  logic [31:2] ex_recovery_pc, recovery_pc_q;
  predictor_update_t predictor_update;
  replay_update_t replay_update;

  always_ff @(posedge clock) begin
    correction_q        <= !reset && (mem_redirect || ex_redirect);
    correction_mem_q    <= !reset && mem_redirect;
    invalidate_replay_q <= !reset && !mem_redirect && fence_refetch;
    // The deferred branch's recovery address was captured in its EX cycle.
    if (!mem_redirect)
      recovery_pc_q <= ex_recovery_pc;
  end

  always_comb begin
    ex_in = id_ex_w;
    ex_in.valid = id_ex_w.valid && !correction_q;
    mem_in = ex_mem_w;
    mem_in.valid = ex_mem_w.valid && !correction_mem_q;
  end

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // ── IF ────────────────────────────────────────────────────────────────
  assign decode_accept = !stall_id && !late_dependency;

  if_stage u_if (
    .clock                (clock),
    .reset                (reset),
    .decode_accept        (decode_accept),
    .correction           (correction_q),
    .recovery_pc          (recovery_pc_q),
    .invalidate_replay    (invalidate_replay_q),
    .predictor_update     (predictor_update),
    .replay_update        (replay_update),
    .imem_addr            (io_imemAddr),
    .imem_data            (io_imemData),
    .imem_ready           (io_imemReady),
    .hazard               (fetch_hazard),
    .out                  (if_id_w)
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
    .rs1_sel  (rs1_sel),
    .rs2_sel  (rs2_sel),
    .load_match     (load_match),
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

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock                (clock),
    .reset                (reset),
    .stall                (stall_ex_mem),
    .cancel_div           (correction_q),
    .in                   (ex_in),
    .fwd_ex_mem           (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb           (wb_w_data),           // MEM/WB-registered result
    .load_data            (load_data),
    .load_writes          (io_dmemREn),
    .out                  (ex_mem_w),
    .fast_write           (ex_fast_write),
    .div_wait             (div_wait),
    .redirect             (ex_redirect),
    .fence_refetch        (fence_refetch),
    .recovery_pc          (ex_recovery_pc)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock        (clock),
    .reset        (reset),
    .hold_wb      (stall_ex_mem),
    .in           (mem_in),
    .dmem_addr    (io_dmemAddr),
    .dmem_wdata   (io_dmemWData),
    .dmem_rdata   (io_dmemRData),
    .dmem_wen     (io_dmemWEn),
    .dmem_ren     (io_dmemREn),
    .dmem_pending (dmem_pending),
    .wb_reg_write (mem_wb_reg_write),
    .load_data    (load_data),
    .redirect     (mem_redirect),
    .predictor_update (predictor_update),
    .replay_update (replay_update),
    .out          (mem_wb_w)
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
    .id_ex_valid     (ex_in.valid),
    .id_ex_late      (id_ex_w.result_kind != RESULT_FAST),
    .id_ex_load      (id_ex_w.result_kind == RESULT_LOAD),
    .id_ex_rd        (id_ex_w.rd),
    .fetch           (fetch_hazard),
    .div_wait        (div_wait),
    .dmem_ready      (io_dmemReady),
    .ex_mem_mem_op   (dmem_pending),
    .load_match      (load_match),
    .late_dependency (late_dependency),
    .stall_id        (stall_id),
    .flush_id        (flush_id),
    .stall_ex_mem    (stall_ex_mem)
  );

  forward_unit u_fwd (
    .id_rs1    (rs1_addr_w),
    .id_rs2    (rs2_addr_w),
    .ex_rd     (id_ex_w.rd),
    .ex_write  (ex_fast_write),
    .mem_rd    (ex_mem_w.rd),
    .mem_write (mem_wb_reg_write),
    .rs1_sel   (rs1_sel),
    .rs2_sel   (rs2_sel)
  );

  // ── RVFI ──────────────────────────────────────────────────────────────
  // The MEM/WB register is the retirement boundary. rvfi_order increments
  // every cycle rvfi_valid is high; CLAUDE.md invariant 4 (riscv-formal
  // unique-check) requires strict +1.
  logic [63:0] rvfi_order_q;

  always_ff @(posedge clock) begin
    if (reset)                rvfi_order_q <= 64'b0;
    else if (mem_wb_w.valid)  rvfi_order_q <= rvfi_order_q + 64'b1;
  end

  always_comb begin
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
    io_rvfi_rd_addr_0   = wb_w_en ? wb_w_addr : 5'b0;
    io_rvfi_rd_wdata_0  = wb_w_en ? wb_w_data : 32'b0;
    io_rvfi_pc_rdata_0  = mem_wb_w.pc;
    io_rvfi_pc_wdata_0  = mem_wb_w.pc_next;
    io_rvfi_mem_addr_0  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask_0 = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask_0 = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata_0 = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata_0 = mem_wb_w.mem_wdata;
  end

endmodule
