// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU, resolves branches and computes the redirect
// target. Owns EX/MEM and exposes its architectural transfer value to ID.
// The core supplies final registered operands and ties the standalone
// forwarding selects to zero, pruning these compatibility muxes.
//
// Standalone forwarding select encoding (constant zero in core):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
//
// Latency:        MUL capture + product + transfer; DIV capture + seven
//                iterations + transfer; other instructions one edge.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               bypass_w_en,
  output logic [4:0]         bypass_rd,
  output logic [31:0]        bypass_data,
  output logic               div_hold,      // hold fetch and ID/EX only
  output logic               mul_hold,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [31:0]        train_pc,
  output logic [31:0]        train_target,
  output logic               train_install,
  output logic               train_conditional,
  output logic               train_taken
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1 = fwd_ex_mem;
      2'd2:    rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (fwd_rs2_sel)
      2'd1:    rs2 = fwd_ex_mem;
      2'd2:    rs2 = fwd_mem_wb;
      default: rs2 = in.rs2_val;
    endcase
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic is_div, div_pending_q;
  logic div_req_valid, div_req_ready, div_rsp_valid, div_rsp_ready;
  logic div_accept;
  logic div_launch;
  ex_mem_t div_saved_q;
  logic [31:0] mul_result;
  logic is_mul, mul_pending_q;
  logic mul_req_valid, mul_req_ready, mul_rsp_valid, mul_rsp_ready;
  logic mul_launch, mul_accept;
  ex_mem_t mul_saved_q;

  assign is_div = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign div_req_valid = is_div && !div_pending_q && !mul_pending_q && !stall && !reset;
  assign div_launch = div_req_valid && div_req_ready;
  assign div_rsp_ready = div_pending_q && !stall && !reset;
  assign div_accept = div_rsp_valid && div_rsp_ready;
  // Release ID/EX on the same edge that transfers the held response.
  assign div_hold = (is_div || div_pending_q) &&
                    !div_accept;

  assign is_mul = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  assign mul_req_valid = is_mul && !mul_pending_q && !div_pending_q && !stall && !reset;
  assign mul_launch = mul_req_valid && mul_req_ready;
  assign mul_rsp_ready = mul_pending_q && !stall && !reset;
  assign mul_accept = mul_rsp_valid && mul_rsp_ready;
  assign mul_hold = (is_mul || mul_pending_q) && !mul_accept;

  alu u_alu (
    .clock(clock), .reset(reset),
    .div_req_valid(div_req_valid), .div_req_ready(div_req_ready),
    .div_rsp_valid(div_rsp_valid), .div_rsp_ready(div_rsp_ready),
    .mul_req_valid(mul_req_valid), .mul_req_ready(mul_req_ready),
    .mul_rsp_valid(mul_rsp_valid), .mul_rsp_ready(mul_rsp_ready),
    .mul_result(mul_result),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  // Balanced 16 -> 8 -> 4 -> 2 -> 1 comparison tree. Leaf j covers
  // bits 2*j+1:2*j; the higher-index child wins unless it is equal.
  logic [15:0] cmp_eq_leaf, cmp_lt_leaf;
  logic [7:0] cmp_eq_l1, cmp_lt_l1;
  logic [3:0] cmp_eq_l2, cmp_lt_l2;
  logic [1:0] cmp_eq_l3, cmp_lt_l3;
  logic cmp_equal, cmp_unsigned_lt, cmp_signed_lt;

  for (genvar j = 0; j < 16; j++) begin : cmp_leaves
    assign cmp_eq_leaf[j] = (rs1[2*j +: 2] == rs2[2*j +: 2]);
    assign cmp_lt_leaf[j] = (rs1[2*j +: 2] < rs2[2*j +: 2]);
  end
  for (genvar j = 0; j < 8; j++) begin : cmp_level1
    assign cmp_eq_l1[j] = cmp_eq_leaf[2*j+1] & cmp_eq_leaf[2*j];
    assign cmp_lt_l1[j] = cmp_lt_leaf[2*j+1] |
                         (cmp_eq_leaf[2*j+1] & cmp_lt_leaf[2*j]);
  end
  for (genvar j = 0; j < 4; j++) begin : cmp_level2
    assign cmp_eq_l2[j] = cmp_eq_l1[2*j+1] & cmp_eq_l1[2*j];
    assign cmp_lt_l2[j] = cmp_lt_l1[2*j+1] |
                         (cmp_eq_l1[2*j+1] & cmp_lt_l1[2*j]);
  end
  for (genvar j = 0; j < 2; j++) begin : cmp_level3
    assign cmp_eq_l3[j] = cmp_eq_l2[2*j+1] & cmp_eq_l2[2*j];
    assign cmp_lt_l3[j] = cmp_lt_l2[2*j+1] |
                         (cmp_eq_l2[2*j+1] & cmp_lt_l2[2*j]);
  end
  assign cmp_equal = cmp_eq_l3[1] & cmp_eq_l3[0];
  assign cmp_unsigned_lt = cmp_lt_l3[1] | (cmp_eq_l3[1] & cmp_lt_l3[0]);
  assign cmp_signed_lt = cmp_unsigned_lt ^ (rs1[31] ^ rs2[31]);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = cmp_equal;
      BR_BNE:  branch_cond = !cmp_equal;
      BR_BLT:  branch_cond = cmp_signed_lt;
      BR_BGE:  branch_cond = !cmp_signed_lt;
      BR_BLTU: branch_cond = cmp_unsigned_lt;
      BR_BGEU: branch_cond = !cmp_unsigned_lt;
      default: branch_cond = 1'b0;
    endcase
    branch_taken  = in.valid && !in.ctrl.is_illegal &&
                    in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : branch_target;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.valid && !in.ctrl.is_illegal &&
                      in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  logic [31:0] sequential_pc, resolved_next_pc;
  logic sequential_match, direct_match, jalr_match, prediction_match;
  logic ex_advance;

  assign sequential_pc = in.pc + 32'd4;
  // Full-width comparisons run in parallel with the outcome comparator.
  // Only a one-bit match is selected after the actual branch decision.
  assign sequential_match = (in.predicted_next_pc == sequential_pc);
  assign direct_match = (in.predicted_next_pc == branch_target);
  assign jalr_match = (in.predicted_next_pc == {jalr_sum[31:1], 1'b0});

  always_comb begin
    resolved_next_pc = sequential_pc;
    prediction_match = sequential_match;
    if (!in.ctrl.is_illegal && !misalign_fault) begin
      if (in.ctrl.is_jump) begin
        resolved_next_pc = jump_target;
        prediction_match = in.ctrl.is_jalr ? jalr_match : direct_match;
      end else if (branch_taken) begin
        resolved_next_pc = branch_target;
        prediction_match = direct_match;
      end
    end
  end

  assign ex_advance = in.valid && !stall && !div_hold && !mul_hold && !reset;
  assign redirect = ex_advance && !prediction_match;
  assign redirect_target = resolved_next_pc;
  assign train_valid = ex_advance;
  assign train_pc = in.pc;
  assign train_target = in.ctrl.is_jump ? jump_target : branch_target;
  assign train_conditional = in.ctrl.is_branch;
  assign train_taken = branch_taken || in.ctrl.is_jump;
  // A not-taken branch with a misaligned candidate must not be installed.
  // All other instructions invalidate only their own matching full tag.
  assign train_install = !in.ctrl.is_illegal &&
                         ((in.ctrl.is_branch && branch_target[1:0] == 2'b00) ||
                          (in.ctrl.is_jump && !misalign_jump));

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t next_payload;

  always_comb begin
    next_payload = '0;
    if (in.valid) begin
      next_payload.pc            = in.pc;
      next_payload.alu_result    = in.ctrl.is_jump ? sequential_pc : alu_result;
      next_payload.write_data    = rs2;
      next_payload.rd            = in.rd;
      next_payload.rs1_addr      = in.rs1_addr;
      next_payload.rs2_addr      = in.rs2_addr;
      next_payload.rs1_val       = rs1;
      next_payload.rs2_val       = rs2;
      next_payload.pc_next       = resolved_next_pc;
      next_payload.branch_taken  = branch_taken;
      next_payload.branch_target = branch_target;
      next_payload.ctrl          = ctrl_with_trap;
      next_payload.instr         = in.instr;
      next_payload.valid         = 1'b1;
    end
  end

  // Ordinary producer metadata/value depend only on the registered EX
  // instruction, never on redirect, advance or younger decode acceptance.
  // A load's address is unavailable as an architectural source value.
  // Blocking M operations expose only the accepted, saved response.
  always_comb begin
    bypass_rd = in.rd;
    bypass_data = in.ctrl.is_jump ? sequential_pc : alu_result;
    bypass_w_en = in.valid && ctrl_with_trap.reg_write &&
                  !ctrl_with_trap.is_illegal && !in.ctrl.mem_read &&
                  (in.rd != 5'b0) &&
                  !is_div && !div_pending_q && !is_mul && !mul_pending_q;
    if (div_accept) begin
      bypass_rd = div_saved_q.rd;
      bypass_data = alu_result;
      bypass_w_en = div_saved_q.valid && div_saved_q.ctrl.reg_write &&
                    !div_saved_q.ctrl.is_illegal && (div_saved_q.rd != 5'b0);
    end else if (mul_accept) begin
      bypass_rd = mul_saved_q.rd;
      bypass_data = mul_result;
      bypass_w_en = mul_saved_q.valid && mul_saved_q.ctrl.reg_write &&
                    !mul_saved_q.ctrl.is_illegal && (mul_saved_q.rd != 5'b0);
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_pending_q <= 1'b0;
      div_saved_q <= '0;
    end else if (div_launch) begin
      div_pending_q <= 1'b1;
      // Save fully forwarded sources and the instruction exactly once.
      div_saved_q <= next_payload;
    end else if (div_accept) begin
      div_pending_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      mul_pending_q <= 1'b0;
      mul_saved_q <= '0;
    end else if (mul_launch) begin
      mul_pending_q <= 1'b1;
      mul_saved_q <= next_payload;
    end else if (mul_accept) begin
      mul_pending_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_accept) begin
      reg_q <= div_saved_q;
      reg_q.alu_result <= alu_result;
    end else if (mul_accept) begin
      reg_q <= mul_saved_q;
      reg_q.alu_result <= mul_result;
    end else if (is_div || div_pending_q || is_mul || mul_pending_q) begin
      // MEM accepts the older EX/MEM entry on this edge. Drain it and
      // inject a side-effect-free bubble instead of reissuing it.
      reg_q <= '0;
    end else begin
      reg_q <= next_payload;
    end
  end

  assign out = reg_q;

endmodule
