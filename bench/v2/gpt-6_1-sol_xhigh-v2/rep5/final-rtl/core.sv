// rtl/core.sv
//
// Top-level wiring for the registered-frontend in-order RV32IM core.
//
//  fetch queue -> decode -> decoded/operand-read -> EX -> MEM -> WB
//             registered early tags   complete operand flops
//   +- stall <- hazard_unit (load-use)
//
// IO port names use the `io_*` Chisel-emit prefix so the existing
// formal/wrapper_si.sv and test/cosim/main.cpp bindings carry through
// byte-for-byte. RVFI port set is the single-channel set described in
// CLAUDE.md invariant 1 under `nret: 1` (declared in core.yaml). The
// orchestrator routes formal to wrapper_si.sv + checks_si.cfg and FPGA
// synth to fpga/core_bench_si.sv for this core. There is no channel 1.
//
// Latency:        fetch, decoded metadata, complete EX operands, EX/MEM
//                 and MEM/WB cross separate edges; cold fill and recovery
//                 include the strictly registered fetch position.
// RVFI fields:    all of them — driven from the MEM/WB register and
//                 the registered final WB data.
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
  // V0 default). Drive 0 to model bus stall — fetch PC holds while
  // queued records can continue to drain into the decoded register.
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
  // dStall — a memory op in EX/MEM holds the backend while MEM/WB
  // captures a bubble. Fetch can fill its three records during the wait.
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
  /* verilator lint_off UNUSEDSIGNAL */
  decoded_t decoded_w;
  /* verilator lint_on UNUSEDSIGNAL */
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  /* verilator lint_off UNUSEDSIGNAL */
  logic       stall_if;
  /* verilator lint_on UNUSEDSIGNAL */
  logic       stall_id, hold_ex, flush_id;
  logic       stall_ex_mem, hold_mem_wb;
  logic       execute_busy;
  logic [31:0] resolved_rs1, resolved_rs2, complete_alu_a, complete_alu_b;
  producer_t ex_fast, ex_link, ex_completed, wb_accepted;
  logic fast_emit, link_emit, completed_emit, held_emit;
  producer_tag_t next_ex_tag;
  /* verilator lint_off UNUSEDSIGNAL */
  producer_tag_t next_mem_tag;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0] incoming_mem_match;
  logic source_wait;
  // Effective producer summaries remain observable for directed checks;
  // capture uses their concrete sources to keep readiness after matching.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0] next_ex_rd, next_mem_rd;
  logic next_ex_w_en, next_mem_w_en;
  logic [31:0] next_ex_data, next_mem_data;
  /* verilator lint_on UNUSEDSIGNAL */

  // Accepted, registered MEM resolution
  logic        redirect;
  logic [31:0] redirect_target;
  logic        train_valid, train_eligible, train_jump, train_taken;
  logic [31:0] train_pc, train_target;

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
    .stall           (stall_id),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .imem_ready      (io_imemReady),
    .train_valid     (train_valid),
    .train_pc        (train_pc),
    .train_eligible  (train_eligible),
    .train_jump      (train_jump),
    .train_taken     (train_taken),
    .train_target    (train_target),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .hold_ex  (hold_ex),
    .squash   (redirect),
    .flush    (flush_id),
    .in       (if_id_w),
    .next_ex_tag (next_ex_tag),
    .incoming_mem_match (incoming_mem_match),
    .mem_hold (held_emit),
    .ex_advance (fast_emit || completed_emit),
    .decoded  (decoded_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .resolved_rs1 (resolved_rs1),
    .resolved_rs2 (resolved_rs2),
    .complete_alu_a (complete_alu_a),
    .complete_alu_b (complete_alu_b),
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
    .stall           (stall_ex_mem),
    .squash          (redirect),
    .div_ready       (io_dmemReady),
    .in              (id_ex_w),
    .out             (ex_mem_w),
    .next_rd         (next_ex_rd),
    .next_w_en       (next_ex_w_en),
    .next_data       (next_ex_data),
    .next_tag        (next_mem_tag),
    .fast_producer   (ex_fast),
    .link_producer   (ex_link),
    .completed_producer (ex_completed),
    .fast_emit       (fast_emit),
    .link_emit       (link_emit),
    .completed_emit  (completed_emit),
    .held_emit       (held_emit),
    .execute_busy    (execute_busy),
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .train_valid     (train_valid),
    .train_pc        (train_pc),
    .train_eligible  (train_eligible),
    .train_jump      (train_jump),
    .train_taken     (train_taken),
    .train_target    (train_target)
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
    .out        (mem_wb_w),
    .next_rd    (next_mem_rd),
    .next_w_en  (next_mem_w_en),
    .next_data  (next_mem_data),
    .accepted_producer (wb_accepted)
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
    .decoded_valid  (decoded_w.valid),
    .source_wait    (source_wait),
    .redirect       (redirect),
    .execute_busy   (execute_busy),
    .imem_ready     (io_imemReady),
    .dmem_ready     (io_dmemReady),
    .ex_mem_mem_op  (ex_mem_w.valid && (ex_mem_w.ctrl.mem_read | ex_mem_w.ctrl.mem_write)),
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .hold_ex        (hold_ex),
    .flush_id       (flush_id),
    .stall_ex_mem   (stall_ex_mem),
    .hold_mem_wb    (hold_mem_wb)
  );

  // Predict the youngest producer position from actual ID/EX priorities.
  // Loads remain matches until accepted data or final trap suppression.
  always_comb begin
    next_ex_tag = '0;
    if (!reset && !flush_id) begin
      if (hold_ex) begin
        next_ex_tag.rd = id_ex_w.rd;
        next_ex_tag.writer = id_ex_w.valid && id_ex_w.ctrl.reg_write;
      end else begin
        next_ex_tag.rd = decoded_w.rd;
        next_ex_tag.writer = decoded_w.valid && decoded_w.ctrl.reg_write;
      end
    end
  end
  assign source_wait = id_ex_w.valid && id_ex_w.ctrl.mem_read &&
                       (decoded_w.provenance.rs1_ex || decoded_w.provenance.rs2_ex);
  // Compare each concrete destination before the late transfer controls,
  // rather than comparing after a hold/completion destination mux. Loads
  // remain possible writers here; MEM later qualifies alignment and data.
  for (genvar s = 0; s < 2; s++) begin : g_early_mem_match
    wire [4:0] source_addr = s == 0 ? if_id_w.instr[24:20] : if_id_w.instr[19:15];
    assign incoming_mem_match[s] =
        (fast_emit && id_ex_w.ctrl.reg_write && id_ex_w.rd != 0 && id_ex_w.rd == source_addr)
      | (completed_emit && ex_completed.w_en && ex_completed.rd != 0 && ex_completed.rd == source_addr)
      | (held_emit && ex_mem_w.valid && ex_mem_w.ctrl.reg_write && ex_mem_w.rd != 0 && ex_mem_w.rd == source_addr);
  end
  forward_unit u_fwd (
    .rs1_addr(rs1_addr_w), .rs2_addr(rs2_addr_w), .provenance(decoded_w.provenance),
    .base_rs1(rs1_data_w), .base_rs2(rs2_data_w),
    .ex_fast(ex_fast), .ex_link(ex_link), .ex_completed(ex_completed),
    .wb_accepted(wb_accepted),
    .fast_emit(fast_emit && !link_emit), .link_emit(link_emit),
    .completed_emit(completed_emit),
    .wb_accept(!reset && !hold_mem_wb),
    .alu_pc_src(decoded_w.ctrl.is_auipc), .alu_imm_src(decoded_w.ctrl.alu_src),
    .pc(decoded_w.pc), .imm(decoded_w.imm),
    .resolved_rs1(resolved_rs1), .resolved_rs2(resolved_rs2),
    .alu_a(complete_alu_a), .alu_b(complete_alu_b)
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
