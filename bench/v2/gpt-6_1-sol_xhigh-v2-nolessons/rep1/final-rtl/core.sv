// rtl/core.sv
//
// Six-stage single-issue RV32IM: IF -> ID -> OF -> EX -> MEM -> WB.
//
// RF lookup and EX/MEM/WB selection end at OF/EX operand flops.
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
`include "core_pkg.sv"
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // imem bus backpressure. Drive 1 for zero-wait single-cycle BRAM (the
  // V0 default). Drive 0 to hold the fetch PC; buffered words can still
  // advance into ID/EX. An empty queue supplies a decode bubble.
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
  // dStall — a memory op in EX/MEM holds the backend; MEM/WB captures a
  // bubble. Fetch continues until both instruction entries are full.
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
  id_of_t  id_of_w;
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       head_valid, decode_accept, stall_id, flush_id;
  logic       operand_accept, stall_of, flush_of, load_use;
  logic       stall_ex_mem, hold_mem_wb;
  logic       div_wait;
  logic       wb_fwd_valid_q;
  logic [4:0] producer_rd;
  logic producer_w_en, normal_w_en, producer_load, mem_fwd_w_en, wb_fwd_w_en;
  logic [31:0] producer_result, normal_result, mem_result;
  logic [31:0] mem_load_data;

  // EX redirect
  logic        redirect;
  logic [31:0] redirect_target;
  logic        train_valid, train_taken;
  logic [5:0]  train_index;

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
    .decode_accept   (decode_accept),
    .imem_ready      (io_imemReady),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .train_valid     (train_valid),
    .train_index     (train_index),
    .train_taken     (train_taken),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .head_valid      (head_valid),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (flush_id),
    .in       (if_id_w),
    .out      (id_of_w)
  );

  operand_stage u_of (
    .clock(clock), .reset(reset), .stall(stall_of), .flush(flush_of),
    .accept(operand_accept), .in(id_of_w),
    .rs1_addr(rs1_addr_w), .rs2_addr(rs2_addr_w),
    .rs1_data(rs1_data_w), .rs2_data(rs2_data_w),
    .ex_rd(producer_rd), .mem_rd(ex_mem_w.rd), .wb_rd(mem_wb_w.rd),
    .ex_w_en(producer_w_en), .ex_normal_w_en(normal_w_en),
    .ex_load(producer_load), .mem_w_en(mem_fwd_w_en), .wb_w_en(wb_fwd_w_en),
    .ex_result(producer_result), .ex_normal_result(normal_result),
    .mem_result(mem_result), .wb_result(wb_w_data),
    .load_use(load_use), .out(id_ex_w)
  );
  assign mem_result = ex_mem_w.ctrl.mem_read ? mem_load_data : ex_mem_w.alu_result;
  assign mem_fwd_w_en = ex_mem_w.valid && ex_mem_w.ctrl.reg_write &&
    !ex_mem_w.ctrl.is_illegal && (!ex_mem_w.ctrl.mem_read || io_dmemREn);
  assign wb_fwd_w_en = wb_fwd_valid_q && mem_wb_w.ctrl.reg_write && !mem_wb_w.ctrl.is_illegal;

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
    .rvfi_mem_rd(ex_mem_w.rd), .rvfi_wb_rd(mem_wb_w.rd),
    .rvfi_mem_w_en(mem_fwd_w_en), .rvfi_wb_w_en(wb_fwd_w_en),
    .rvfi_mem_data(mem_result), .rvfi_wb_data(wb_w_data),
    .producer_rd(producer_rd), .producer_w_en(producer_w_en),
    .normal_w_en(normal_w_en), .producer_load(producer_load),
    .producer_result(producer_result), .normal_result(normal_result),
    .out             (ex_mem_w),
    .div_wait        (div_wait),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .train_valid     (train_valid),
    .train_index     (train_index),
    .train_taken     (train_taken)
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
    .load_data  (mem_load_data),
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
    .load_use       (load_use),
    .redirect       (redirect),
    .div_wait       (div_wait),
    .head_valid     (head_valid),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.valid && (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write)),
    .decode_accept  (decode_accept),
    .operand_accept (operand_accept),
    .stall_id       (stall_id),
    .flush_id       (flush_id),
    .stall_of       (stall_of),
    .flush_of       (flush_of),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  // A valid WB payload remains a forwarding source after its single
  // retirement while dStall clears only valid. Track that provenance
  // separately so invalid instructions never become bypass producers.
  always_ff @(posedge clock) begin
    if (reset) wb_fwd_valid_q <= 1'b0;
    else if (!hold_mem_wb) wb_fwd_valid_q <= ex_mem_w.valid;
  end

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
