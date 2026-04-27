// rtl/core.sv
//
// Top-level wiring for the 5-stage in-order RV32IM core.
//
//  IF -> ID -> EX -> MEM -> WB
//   |    |     ^
//   |    +-----+    forward_unit drives EX-stage rs1/rs2 muxes
//   |               from EX/MEM and MEM/WB
//   +- stall <- hazard_unit (load-use)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper.sv and chisel/test/cosim/main.cpp bindings carry
// through byte-for-byte. RVFI port set is the 32 signals listed in
// CLAUDE.md invariant 1.
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
  // dmem
  output logic [31:0] io_dmemAddr,
  input  logic [31:0] io_dmemRData,
  output logic [31:0] io_dmemWData,
  output logic [3:0]  io_dmemWEn,
  output logic        io_dmemREn,
  // RVFI
  output logic        io_rvfi_valid,
  output logic [63:0] io_rvfi_order,
  output logic [31:0] io_rvfi_insn,
  output logic        io_rvfi_trap,
  output logic        io_rvfi_halt,
  output logic        io_rvfi_intr,
  output logic [1:0]  io_rvfi_mode,
  output logic [1:0]  io_rvfi_ixl,
  output logic [4:0]  io_rvfi_rs1_addr,
  output logic [31:0] io_rvfi_rs1_rdata,
  output logic [4:0]  io_rvfi_rs2_addr,
  output logic [31:0] io_rvfi_rs2_rdata,
  output logic [4:0]  io_rvfi_rd_addr,
  output logic [31:0] io_rvfi_rd_wdata,
  output logic [31:0] io_rvfi_pc_rdata,
  output logic [31:0] io_rvfi_pc_wdata,
  output logic [31:0] io_rvfi_mem_addr,
  output logic [3:0]  io_rvfi_mem_rmask,
  output logic [3:0]  io_rvfi_mem_wmask,
  output logic [31:0] io_rvfi_mem_rdata,
  output logic [31:0] io_rvfi_mem_wdata
);

  // ── Inter-stage wires ──────────────────────────────────────────────────
  if_id_t  if_id_w;
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_if, stall_id, flush_if, flush_id;
  logic [1:0] fwd_rs1_sel, fwd_rs2_sel;

  // EX redirect
  logic        redirect;
  logic [31:0] redirect_target;

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
    .stall           (stall_if),
    .flush           (flush_if),
    .redirect        (redirect),
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
    .clock           (clock),
    .reset           (reset),
    .in              (id_ex_w),
    .fwd_rs1_sel     (fwd_rs1_sel),
    .fwd_rs2_sel     (fwd_rs2_sel),
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .fwd_mem_wb      (wb_w_data),            // WB-stage's write-mux output
    .out             (ex_mem_w),
    .redirect        (redirect),
    .redirect_target (redirect_target)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
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
    .if_id_rs1      (if_id_w.instr[19:15]),
    .if_id_rs2      (if_id_w.instr[24:20]),
    .redirect       (redirect),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .flush_if       (flush_if),
    .flush_id       (flush_id)
  );

  forward_unit u_fwd (
    .id_ex_rs1   (id_ex_w.rs1_addr),
    .id_ex_rs2   (id_ex_w.rs2_addr),
    .ex_mem_rd   (ex_mem_w.rd),
    .ex_mem_w_en (ex_mem_w.ctrl.reg_write),
    .mem_wb_rd   (mem_wb_w.rd),
    .mem_wb_w_en (mem_wb_w.ctrl.reg_write),
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
    rd_wen = mem_wb_w.ctrl.reg_write && (mem_wb_w.rd != 5'b0);

    io_rvfi_valid     = mem_wb_w.valid;
    io_rvfi_order     = rvfi_order_q;
    io_rvfi_insn      = mem_wb_w.instr;
    io_rvfi_trap      = mem_wb_w.ctrl.is_illegal;
    io_rvfi_halt      = 1'b0;
    io_rvfi_intr      = 1'b0;
    io_rvfi_mode      = 2'd3;     // M-mode only
    io_rvfi_ixl       = 2'd1;     // 32-bit ISA
    io_rvfi_rs1_addr  = mem_wb_w.rs1_addr;
    io_rvfi_rs1_rdata = mem_wb_w.rs1_val;
    io_rvfi_rs2_addr  = mem_wb_w.rs2_addr;
    io_rvfi_rs2_rdata = mem_wb_w.rs2_val;
    io_rvfi_rd_addr   = rd_wen ? mem_wb_w.rd     : 5'b0;
    io_rvfi_rd_wdata  = rd_wen ? wb_w_data       : 32'b0;
    io_rvfi_pc_rdata  = mem_wb_w.pc;
    io_rvfi_pc_wdata  = mem_wb_w.pc_next;
    io_rvfi_mem_addr  = mem_wb_w.mem_addr;
    io_rvfi_mem_rmask = mem_wb_w.mem_rmask;
    io_rvfi_mem_wmask = mem_wb_w.mem_wmask;
    io_rvfi_mem_rdata = mem_wb_w.mem_rdata;
    io_rvfi_mem_wdata = mem_wb_w.mem_wdata;
  end

endmodule
