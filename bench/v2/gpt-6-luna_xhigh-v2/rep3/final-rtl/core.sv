// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    +-----+    decode captures the freshest forwarded source values
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
  id_ex_t  id_ex_raw;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_if, stall_id, flush_if, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       ex_busy;
  logic [2:0] fwd_rs1_sel, fwd_rs2_sel;

  // EX redirect
  logic        redirect;
  logic        redirect_fire;
  logic [31:0] redirect_target;

  // IF/ID may accept the sequential fetch on a redirect cycle. Remember
  // whether that instruction entered ID/EX and mask it before any EX-side
  // consumer sees it. The token follows ID/EX through holds.
  logic squash_token_q;
  logic redirect_seen_q;

  // A branch can stay in ID/EX while an older data transaction stalls MEM.
  // IF has already installed the redirect target in PC on the first cycle;
  // later cycles of the same redirect must not squash that target fetch.
  // Remember the redirect only while ID/EX is held, then clear the bit on
  // the accepting cycle so a target instruction that is itself a branch
  // can start a fresh recovery immediately.
  always_ff @(posedge clock) begin
    if (reset) redirect_seen_q <= 1'b0;
    else       redirect_seen_q <= redirect && stall_id;
  end

  // The redirect's first cycle updates PC even if the pipeline is stalled.
  // If the branch remains held, suppress repeated redirect levels so the
  // target can advance normally on the cycle ID/EX accepts it.
  assign redirect_fire = redirect && !redirect_seen_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      squash_token_q <= 1'b0;
    end else if (flush_id) begin
      // A load-use flush writes a bubble even though stall_id is asserted.
      squash_token_q <= 1'b0;
    end else if (!stall_id) begin
      // Tokenize only the fetch from the first redirect cycle. If the
      // branch remains held, redirect_seen_q prevents tagging the target
      // fetch after IF has already moved PC there.
      squash_token_q <= redirect_fire && if_id_w.valid;
    end
  end

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;
  logic        id_ex_fwd_valid;
  logic [4:0]  id_ex_fwd_rd;
  logic [31:0] id_ex_fwd_data;
  logic [31:0] mem_load_fwd_data;
  logic        mem_load_fwd_valid;

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .stall           (stall_if),
    .flush           (flush_if),
    .redirect        (redirect_fire),
    .redirect_target (redirect_target),
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
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .fwd_rs1_sel       (fwd_rs1_sel),
    .fwd_rs2_sel       (fwd_rs2_sel),
    .fwd_ex_data       (id_ex_fwd_data),
    .fwd_ex_mem_data   (ex_mem_w.alu_result),
    .fwd_mem_load_data (mem_load_fwd_data),
    .fwd_mem_wb_data   (wb_w_data),
    .out      (id_ex_raw)
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
    .busy            (ex_busy),
    .in              (id_ex_raw),
    .squash          (squash_token_q),
    .out             (ex_mem_w),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .fwd_valid       (id_ex_fwd_valid),
    .fwd_rd          (id_ex_fwd_rd),
    .fwd_data        (id_ex_fwd_data)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (hold_mem_wb),
    .dmem_ready (io_dmemReady),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .load_forward_data  (mem_load_fwd_data),
    .load_forward_valid (mem_load_fwd_valid),
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
    .id_ex_mem_read (id_ex_raw.ctrl.mem_read && !squash_token_q),
    .id_ex_rd       (id_ex_raw.rd),
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .ex_busy        (ex_busy),
    .imem_ready     (io_imemReady),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  forward_unit u_fwd (
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .id_ex_rd       (id_ex_fwd_rd),
    .id_ex_w_en     (id_ex_fwd_valid),
    .ex_mem_rd      (ex_mem_w.rd),
    .ex_mem_w_en    (ex_mem_w.valid && ex_mem_w.ctrl.reg_write &&
                     !ex_mem_w.ctrl.mem_to_reg),
    .mem_load_rd    (ex_mem_w.rd),
    .mem_load_valid (mem_load_fwd_valid),
    .mem_wb_rd      (mem_wb_w.rd),
    .mem_wb_w_en    (wb_w_en),
    .fwd_rs1        (fwd_rs1_sel),
    .fwd_rs2        (fwd_rs2_sel)
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
