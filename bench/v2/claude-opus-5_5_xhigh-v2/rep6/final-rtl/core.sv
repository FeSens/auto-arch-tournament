// rtl/core.sv
//
// Top-level wiring for the 4-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM(+WB)
//   |    |  ^  ^      |
//   |    |  |  +------+ forward_unit drives the EX-stage rs1/rs2 2:1 muxes
//   |    |  |           (EX/MEM or the ID/EX register value)
//   |    |  +---------- MEM merged result bypassed into ID (last select),
//   |    |              then the registered write port w_q (MEM/WB.{w_en,
//   |    |              rd, result}) writes the flip-flop regfile one cycle
//   |    |              later (write-first bypass in ID)
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
  // freezes back to MEM; no retire / regfile write; the LOAD/STORE waits
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
  logic       stall_ex_mem;
  logic [31:0] mem_nl_w;      // MEM result, non-load half
  logic [31:0] mem_ld_w;      // MEM load data (ungated)
  opsel_t     sel_rs1, sel_rs2;

  // EX redirect controls (take_* = taken branch, last mux select)
  logic [3:0]  take_pc;
  logic        pc_hold;
  logic [1:0]  take_kill;
  logic        ex_jump;
  logic        ex_jlink;
  logic        ex_p_ok_lo;
  logic        ex_p_ok_hi;
  logic        ex_jalr_go;
  logic [31:0] ex_agu_target;
  logic [31:0] ex_br_target;
  logic [31:0] ex_link;
  logic        ex_busy;

  // regfile interface (driven by ID + WB stages)
  logic [4:0]  rs1_addr_w;
  logic [4:0]  rs2_addr_w;
  logic [31:0] rs1_data_w;
  logic [31:0] rs2_data_w;
  logic        wb_w_en;
  logic [4:0]  wb_w_addr;
  logic [31:0] wb_w_data;

  // fetch predictor
  logic [11:2] pc_alt_w;
  logic [29:0] bp_inc;
  logic        bp_pq;
  logic [13:0] bp_pq_off;
  logic [9:0]  bp_pk_idx;
  logic        bp_pk_tm;
  logic [1:0]  bp_pk_ctr;
  logic        bp_pk_v;
  logic        upd_we;
  logic [5:0]  upd_idx;
  logic [20:0] upd_data;

  fetch_pred u_bp (
    .clock  (clock),
    .reset  (reset),
    .hold   (pc_hold),
    .jump   (ex_jump),
    .pc_alt (pc_alt_w),
    .we     (upd_we),
    .waddr  (upd_idx),
    .wdata  (upd_data),
    .inc    (bp_inc),
    .pq     (bp_pq),
    .pq_off (bp_pq_off),
    .pk_idx (bp_pk_idx),
    .pk_tm  (bp_pk_tm),
    .pk_ctr (bp_pk_ctr),
    .pk_v   (bp_pk_v)
  );

  // ── IF ────────────────────────────────────────────────────────────────
  if_stage u_if (
    .clock           (clock),
    .reset           (reset),
    .hold            (pc_hold),
    .flush           (flush_if),
    .take            (take_pc),
    .br_target       (ex_br_target),
    .jump            (ex_jump),
    .jlink           (ex_jlink),
    .p_ok_lo         (ex_p_ok_lo),
    .p_ok_hi         (ex_p_ok_hi),
    .inc             (bp_inc),
    .pc_alt_o        (pc_alt_w),
    .jalr_go         (ex_jalr_go),
    .agu_target      (ex_agu_target),
    .link            (ex_link),
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
    .take_kill(take_kill),
    .in       (if_id_w),
    .pq       (bp_pq),
    .pq_off   (bp_pq_off),
    .pk_idx   (bp_pk_idx),
    .pk_tm    (bp_pk_tm),
    .pk_ctr   (bp_pk_ctr),
    .pk_v     (bp_pk_v),
    .sel_rs1  (sel_rs1),
    .sel_rs2  (sel_rs2),
    .m_ok     (ex_mem_w.w_ok),
    .m_rd     (ex_mem_w.rd),
    .m_nl     (mem_nl_w),
    .m_ld_data(mem_ld_w),
    .w_en     (wb_w_en),
    .w_addr   (wb_w_addr),
    .w_data   (wb_w_data),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .out      (id_ex_w)
  );

  reg_file u_rf (
    .clock    (clock),
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
    .fwd_add         (ex_mem_w.add_q),       // EX/MEM-registered adder sum
    .fwd_oth         (ex_mem_w.oth_q),       // EX/MEM-registered other groups
    .out             (ex_mem_w),
    .take_pc         (take_pc),
    .take_kill       (take_kill),
    .jump            (ex_jump),
    .jlink           (ex_jlink),
    .p_ok_lo         (ex_p_ok_lo),
    .p_ok_hi         (ex_p_ok_hi),
    .jalr_go         (ex_jalr_go),
    .agu_target      (ex_agu_target),
    .br_target       (ex_br_target),
    .link            (ex_link),
    .ex_busy         (ex_busy)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .stall      (stall_ex_mem),
    .in         (ex_mem_w),
    .nl_result  (mem_nl_w),
    .ld_data    (mem_ld_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .out        (mem_wb_w),
    .upd_we     (upd_we),
    .upd_idx    (upd_idx),
    .upd_data   (upd_data)
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
    .id_ex_lu_arm   (id_ex_w.lu_arm),
    .id_ex_rd       (id_ex_w.rd),
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .id_ex_jump     (id_ex_w.ctrl.is_jump),
    .imem_ready     (io_imemReady),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write),
    .ex_busy        (ex_busy),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold           (pc_hold)
  );

  forward_unit u_fwd (
    .if_id_rs1   (if_id_w.instr[19:15]),
    .if_id_rs2   (if_id_w.instr[24:20]),
    .id_ex_rd    (id_ex_w.rd),
    .id_ex_w_en  (id_ex_w.ctrl.reg_write),
    .sel_rs1     (sel_rs1),
    .sel_rs2     (sel_rs2)
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
    io_rvfi_rd_wdata_0  = rd_wen ? mem_wb_w.result : 32'b0;
    io_rvfi_pc_rdata_0  = mem_wb_w.pc;
    io_rvfi_pc_wdata_0  = mem_wb_w.pc_next;
    io_rvfi_mem_addr_0  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask_0 = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask_0 = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata_0 = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata_0 = mem_wb_w.mem_wdata;
  end

endmodule
