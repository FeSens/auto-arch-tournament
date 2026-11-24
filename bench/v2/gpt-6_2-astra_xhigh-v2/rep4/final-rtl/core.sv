// rtl/core.sv
//
// Top-level wiring for the in-order RV32IM core.
//
//  IF -> ID -> operand collection -> EX -> MEM -> WB
//  Collection resolves older writers and qualifies the adjacent producer's
//  bypass while that producer is in EX.
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
// RVFI fields:    driven from the MEM/WB register.
module core (
  input  logic        clock,
  input  logic        reset,
  // imem
  output logic [31:0] io_imemAddr,
  input  logic [31:0] io_imemData,
  // A verified replay row can supply the instruction while imem is stalled.
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
  id_ex_t  waiting;
  id_ex_t  id_ex_w;
  ex_mem_t ex_mem_w;
  mem_wb_t mem_wb_w;

  // hazard / forward
  logic       stall_if, stall_id, stall_ex, result_hazard;
  logic       mem_wait, div_wait, repair;
  logic [31:0] div_result;
  logic [1:0] fwd_rs1_sel, fwd_rs2_sel;
  logic [31:0] mem_wb_value;
  logic        mem_writer, check_load_q;
  logic        ex_writer;
  logic        match_rs1, match_rs2;
  logic        bypass_rs1_q, bypass_rs2_q;
  logic        bypass_alu_a_q, bypass_alu_b_q;
  logic        early_hit, retry_hit, reference;
  logic [31:0] candidate, early_word, retry_word, ref_data;
  logic [31:0] effective_addr;
  logic [3:0]  ref_mask;
  logic [31:1] expected_base_q, expected_base_carry_q;
  logic [31:0] direct_target_q, sequential_pc_q;
  logic        redirect_on_taken_q, redirect_on_fallthrough_q, redirect_always_q;

  // EX redirect
  logic        redirect;
  logic [31:0] redirect_target;
  btb_update_t btb_update;

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
    .redirect        (redirect),
    .redirect_target (redirect_target),
    .update          (btb_update),
    .imem_ready      (io_imemReady),
    .imem_addr       (io_imemAddr),
    .imem_data       (io_imemData),
    .out             (if_id_w)
  );

  // ── ID + regfile ──────────────────────────────────────────────────────
  id_stage u_id (
    .clock    (clock),
    .reset    (reset),
    .stall    (stall_id),
    .flush    (redirect),
    .in       (if_id_w),
    .rs1_addr (rs1_addr_w),
    .rs2_addr (rs2_addr_w),
    .rs1_data (rs1_data_w),
    .rs2_data (rs2_data_w),
    .wb_w_en  (wb_w_en),
    .wb_w_addr(wb_w_addr),
    .wb_w_data(wb_w_data),
    .out      (waiting)
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

  // ── Operand collection ────────────────────────────────────────────────
  assign mem_writer = ex_mem_w.ctrl.reg_write;
  forward_unit u_fwd (
    .id_ex_rs1   (waiting.rs1_addr),
    .id_ex_rs2   (waiting.rs2_addr),
    .ex_mem_rd   (ex_mem_w.rd),
    .ex_mem_w_en (mem_writer),
    .mem_wb_rd   (mem_wb_w.rd),
    .mem_wb_w_en (mem_wb_w.ctrl.reg_write),
    .fwd_rs1     (fwd_rs1_sel),
    .fwd_rs2     (fwd_rs2_sel)
  );

  id_ex_t collected;
  wire adjacent_rs1 = match_rs1 && ex_writer;
  wire adjacent_rs2 = match_rs2 && ex_writer;
  always_comb begin
    collected = waiting;
    for (int i = 0; i < $bits(waiting.result_sel); i++) begin
      collected.result_sel[i] = !waiting.ctrl.is_jump && !waiting.ctrl.mem_read &&
                                waiting.ctrl.alu_op == 5'(i);
    end
    collected.use_mul_low = waiting.ctrl.alu_op == ALU_MUL;
    collected.mul_rhs_signed = waiting.ctrl.alu_op == ALU_MULH;
    collected.mul_lhs_signed = collected.mul_rhs_signed || waiting.ctrl.alu_op == ALU_MULHSU;
    collected.use_mul_high = collected.mul_lhs_signed || waiting.ctrl.alu_op == ALU_MULHU;
    collected.rs1_val =
      ({32{repair || (!adjacent_rs1 && fwd_rs1_sel == 1)}} & mem_wb_value) |
      ({32{!repair && !adjacent_rs1 && fwd_rs1_sel == 2}} & wb_w_data) |
      ({32{!repair && !adjacent_rs1 && fwd_rs1_sel == 0}} & waiting.rs1_val);
    collected.rs2_val =
      ({32{repair || (!adjacent_rs2 && fwd_rs2_sel == 1)}} & mem_wb_value) |
      ({32{!repair && !adjacent_rs2 && fwd_rs2_sel == 2}} & wb_w_data) |
      ({32{!repair && !adjacent_rs2 && fwd_rs2_sel == 0}} & waiting.rs2_val);
  end

  assign match_rs1 = id_ex_w.rd != 0 && id_ex_w.rd == waiting.rs1_addr;
  assign match_rs2 = id_ex_w.rd != 0 && id_ex_w.rd == waiting.rs2_addr;

  // The prediction need only name a word within the resident page. Use
  // registered sources here, including the unverified raw pointer in EX.
  wire next_pointer = waiting.valid && waiting.ctrl.mem_read && waiting.rd != 0 &&
                      waiting.rd == rs1_addr_w;
  wire next_mem_base = id_ex_w.valid && id_ex_w.ctrl.reg_write && id_ex_w.rd != 0 &&
                       id_ex_w.rd == rs1_addr_w;
  wire next_wb_base = mem_writer && ex_mem_w.rd != 0 && ex_mem_w.rd == rs1_addr_w;
  logic [3:0] guess_source;
  always_ff @(posedge clock) begin
    if (!stall_id) begin
      guess_source[0] <= next_pointer;
      guess_source[1] <= !next_pointer && next_mem_base;
      guess_source[2] <= !next_pointer && !next_mem_base && next_wb_base;
      guess_source[3] <= !next_pointer && !next_mem_base && !next_wb_base;
    end
  end
  wire [11:0] base_guess = ({12{guess_source[0]}} & candidate[11:0]) |
                           ({12{guess_source[1]}} & ex_mem_w.alu_result[11:0]) |
                           ({12{guess_source[2]}} & wb_w_data[11:0]) |
                           ({12{guess_source[3]}} & waiting.rs1_val[11:0]);
  /* verilator lint_off UNUSEDSIGNAL */
  wire [5:0] low_guess = base_guess[5:0] + waiting.imm[5:0];
  /* verilator lint_on UNUSEDSIGNAL */
  wire [5:0] high_guess = base_guess[11:6] + waiting.imm[11:6] + {5'b0, waiting.imm[5]};
  load_predictor u_predict (
    .clock, .reset, .collect(!stall_ex), .execute(!mem_wait),
    .guess({high_guess, low_guess[5:2]}), .exact_addr(effective_addr[31:2]),
    .candidate, .early_word, .retry_word, .early_hit, .retry_hit,
    .reference, .ref_addr(ex_mem_w.mem_addr[19:2]), .ref_mask, .ref_data
  );

  wire [31:0] predicted_target = {12'b0, waiting.prediction.target, 2'b0};
  wire [31:0] direct_target = waiting.pc + waiting.imm;
  wire bad_direct = direct_target[1:0] != 0 ? waiting.prediction.taken :
                    (!waiting.prediction.taken || direct_target != predicted_target);
  assign repair = id_ex_w.valid && check_load_q && !early_hit;
  always_ff @(posedge clock) begin
    if (!stall_ex) begin
      id_ex_w <= collected;
      bypass_rs1_q <= adjacent_rs1;
      bypass_rs2_q <= adjacent_rs2;
      bypass_alu_a_q <= adjacent_rs1 && !waiting.ctrl.is_auipc;
      bypass_alu_b_q <= adjacent_rs2 && !waiting.ctrl.alu_src;
      expected_base_q <= predicted_target[31:1] - waiting.imm[31:1];
      expected_base_carry_q <= predicted_target[31:1] + ~waiting.imm[31:1];
      direct_target_q <= direct_target;
      sequential_pc_q <= waiting.pc + 32'd4;
      redirect_on_taken_q <= waiting.ctrl.is_branch && bad_direct;
      redirect_on_fallthrough_q <= waiting.ctrl.is_branch && waiting.prediction.taken;
      redirect_always_q <= (!waiting.ctrl.is_jalr && waiting.ctrl.is_jump && bad_direct) ||
                           (!waiting.ctrl.is_jump && !waiting.ctrl.is_branch && waiting.prediction.taken) ||
                           (waiting.instr[6:0] == 7'h0f && waiting.instr[14:12] == 1);
    end else if (repair && !mem_wait) begin
      if (bypass_rs1_q) id_ex_w.rs1_val <= collected.rs1_val;
      if (bypass_rs2_q) id_ex_w.rs2_val <= collected.rs2_val;
      bypass_rs1_q <= 1'b0;
      bypass_rs2_q <= 1'b0;
      bypass_alu_a_q <= 1'b0;
      bypass_alu_b_q <= 1'b0;
    end
    if (!mem_wait)
      check_load_q <= !stall_ex && id_ex_w.ctrl.mem_read && (adjacent_rs1 || adjacent_rs2);
    if (reset || redirect || (!stall_ex && result_hazard))
      id_ex_w.valid <= 1'b0;
  end

  // ── EX ────────────────────────────────────────────────────────────────
  ex_stage u_ex (
    .clock           (clock),
    .reset           (reset),
    .stall           (mem_wait),
    .in              (id_ex_w),
    .bypass_rs1      (bypass_rs1_q),
    .bypass_rs2      (bypass_rs2_q),
    .bypass_alu_a    (bypass_alu_a_q),
    .bypass_alu_b    (bypass_alu_b_q),
    .repair, .candidate,
    .expected_base   (expected_base_q),
    .expected_base_carry(expected_base_carry_q),
    .branch_target   (direct_target_q),
    .sequential_pc   (sequential_pc_q),
    .redirect_on_taken(redirect_on_taken_q),
    .redirect_on_fallthrough(redirect_on_fallthrough_q),
    .redirect_always (redirect_always_q),
    .bypass_writer   (ex_writer),
    .effective_addr,
    .fwd_ex_mem      (ex_mem_w.alu_result),  // EX/MEM-registered ALU result
    .out             (ex_mem_w),
    .div_wait        (div_wait),
    .div_result      (div_result),
    .update          (btb_update),
    .redirect        (redirect),
    .redirect_target (redirect_target)
  );

  // ── MEM ───────────────────────────────────────────────────────────────
  mem_stage u_mem (
    .clock      (clock),
    .reset      (reset),
    .hold_wb    (mem_wait),
    .ex_addr    (effective_addr),
    .dmem_ready (io_dmemReady),
    .early_hit, .retry_hit, .early_word, .retry_word,
    .reference, .ref_mask, .ref_data,
    .div_result (div_result),
    .in         (ex_mem_w),
    .dmem_addr  (io_dmemAddr),
    .dmem_wdata (io_dmemWData),
    .dmem_rdata (io_dmemRData),
    .dmem_wen   (io_dmemWEn),
    .dmem_ren   (io_dmemREn),
    .wb_value   (mem_wb_value),
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
    .id_ex_late_result (waiting.valid && id_ex_w.valid && id_ex_w.ctrl.alu_op > ALU_MUL),
    .id_ex_rd       (id_ex_w.rd),
    .waiting_rs1    (waiting.rs1_addr),
    .waiting_rs2    (waiting.rs2_addr),
    .div_wait       (div_wait),
    .fetch_available(if_id_w.valid),
    .mem_wait, .repair,
    .stall_if       (stall_if),
    .stall_id       (stall_id),
    .stall_ex       (stall_ex),
    .result_hazard  (result_hazard)
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
