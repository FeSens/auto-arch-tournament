// rtl/ex_stage.sv
//
// Execute stage. Applies the operand selects registered by decode, runs
// the ALU, forms the data address, and resolves control transfers. Owns
// the EX/MEM pipeline register.
//
// Latency:        1 cycle for the ALU and 9 cycles for division.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               cancel_div,     // registered correction pulse
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,
  input  logic [31:0]        load_data,
  input  logic               load_writes,
  output ex_mem_t  out,
  output logic               fast_write,
  output logic               div_wait,
  output logic               redirect,
  output logic               fence_refetch,
  output logic [31:2]        recovery_pc
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = ({32{in.rs1_sel.local_value}} & in.rs1_val)
             | ({32{in.rs1_sel.ex_mem}} & fwd_ex_mem)
             | ({32{in.rs1_sel.mem_wb}} & fwd_mem_wb);
  assign rs2 = ({32{in.rs2_sel.local_value}} & in.rs2_val)
             | ({32{in.rs2_sel.ex_mem}} & fwd_ex_mem)
             | ({32{in.rs2_sel.mem_wb}} & fwd_mem_wb);

  // The LSU and JALR both use the forwarded base plus the decoded immediate.
  logic [31:0] effective_addr;
  assign effective_addr = rs1 + in.imm;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  assign alu_a = ({32{in.alu_a_sel.local_value}} & in.alu_a_local)
               | ({32{in.alu_a_sel.ex_mem}} & fwd_ex_mem)
               | ({32{in.alu_a_sel.mem_wb}} & fwd_mem_wb);
  assign alu_b = ({32{in.alu_b_sel.local_value}} & in.alu_b_local)
               | ({32{in.alu_b_sel.ex_mem}} & fwd_ex_mem)
               | ({32{in.alu_b_sel.mem_wb}} & fwd_mem_wb);

  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  mul_products_t mul_products;
  mul_unit u_mul (
    .op       (in.ctrl.alu_op),
    .a        (rs1),
    .b        (rs2),
    .products (mul_products)
  );

  // ID/EX retains the original instruction while the divider owns EX.
  // Capture the forwarded values on issue, before older stages drain.
  logic        is_div, div_ready, div_valid;
  logic        div_negate;
  logic [31:0] div_magnitude, div_rs1, div_rs2;

  assign is_div = in.valid && in.result_kind == RESULT_DIV;
  assign div_wait = is_div && !div_valid;

  div_unit u_div (
    .clock            (clock),
    .reset            (reset || cancel_div),
    .request_valid    (is_div && div_ready && !stall),
    .request_ready    (div_ready),
    .op               (in.ctrl.alu_op),
    .a                (rs1),
    .b                (rs2),
    .result_valid     (div_valid),
    .result_ready     (!stall),
    .result_magnitude (div_magnitude),
    .result_negate    (div_negate),
    .saved_a          (div_rs1),
    .saved_b          (div_rs2)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken, resolved_taken;
  logic [31:0] branch_target, jump_target, fallthrough;
  logic        branch_equal, branch_less, signs_differ;

  // Signedness only changes the ordering of the top bit.
  assign signs_differ = rs1[31] ^ rs2[31];
  assign branch_less = signs_differ ? rs1[31] ^ in.ctrl.branch_op[1]
                                    : rs1[30:0] < rs2[30:0];
  assign branch_equal = rs1 == rs2;
  assign branch_cond = (in.ctrl.branch_op[2] ? branch_less : branch_equal)
                     ^ in.ctrl.branch_op[0];

  assign branch_taken = in.ctrl.is_branch && branch_cond;
  assign branch_target = in.pc + in.imm;
  assign jump_target   = in.ctrl.is_jalr ? {effective_addr[31:1], 1'b0} : branch_target;
  assign fallthrough   = in.pc + 32'd4;
  // On a miss the successor is always the one fetch did not select.
  assign recovery_pc = ({30{in.recover_fallthrough}} & fallthrough[31:2])
                     | ({30{in.recover_direct}}    & branch_target[31:2])
                     | ({30{in.recover_indirect}}  & effective_addr[31:2]);

  logic [31:0] other_operand;
  late_branch_t late_compare;

  // Keep the load off the ordinary forwarding network. The compare has
  // a fixed orientation (load vs. other) that MEM converts to rs1 vs. rs2.
  assign other_operand = ({32{in.load_other_rs1}} & in.rs1_val)
                       | ({32{in.load_other_rs2}} & in.rs2_val)
                       | ({32{in.load_other_wb}}  & fwd_mem_wb);
  for (genvar i = 0; i < 4; i++) begin : g_load_compare
    assign late_compare.byte_equal[i] = load_data[i*8 +: 8] == other_operand[i*8 +: 8];
    assign late_compare.byte_less[i]  = load_data[i*8 +: 8] <  other_operand[i*8 +: 8];
  end
  assign late_compare.match = in.load_match;
  assign late_compare.load_writes = load_writes;
  assign late_compare.load_sign = load_data[31];
  assign late_compare.other_sign = other_operand[31];
  assign late_compare.predicted_taken = in.predicted_taken;
  assign late_compare.target = branch_target[31:2];
  assign late_compare.fallthrough = fallthrough[31:2];

  // Direct transfers start at a word-aligned PC. JALR clears bit 0 of
  // its target, leaving bit 1 of the two-bit sum to determine alignment.
  logic misalign_branch, misalign_jump, jump_target_misaligned;
  logic [1:0] jalr_low_sum;
  ctrl_t ctrl_with_trap;

  assign jalr_low_sum = rs1[1:0] + in.imm[1:0];
  assign jump_target_misaligned = in.ctrl.is_jalr ? |(jalr_low_sum & 2'b10) : in.imm[1];
  assign misalign_branch = branch_taken && in.imm[1];
  assign misalign_jump = in.ctrl.is_jump && jump_target_misaligned;
  assign resolved_taken = (branch_taken && !in.imm[1])
                       || (in.ctrl.is_jump && !jump_target_misaligned);

  always_comb begin
    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.is_illegal = in.ctrl.is_illegal || misalign_branch || misalign_jump;
    ctrl_with_trap.reg_write = in.ctrl.reg_write && !misalign_jump;
  end

  // Branches have no writeback. Jump alignment alone can suppress a link.
  assign fast_write = in.valid && in.result_kind == RESULT_FAST
                    && in.ctrl.reg_write && !misalign_jump;

  logic branch_miss, jump_miss;
  // Decode folds branch polarity and prediction into one bit. Misaligned
  // direct branches fall through on a trap and are always predicted that way.
  assign branch_miss = (in.branch_recover_eq && (branch_equal ^ in.branch_recover_invert))
                    || (in.branch_recover_order && (branch_less ^ in.branch_recover_invert));
  assign jump_miss = in.ctrl.is_jump && (jump_target_misaligned == in.predicted_taken);
  assign fence_refetch = in.valid && !stall && in.fence_i;
  assign redirect = in.valid && !stall && (branch_miss || jump_miss || in.fence_i);

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.effective_addr <= effective_addr;

      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= alu_result;
      reg_q.result_kind   <= in.result_kind;
      reg_q.mul_products  <= mul_products;
      reg_q.div_magnitude <= div_magnitude;
      reg_q.div_negate    <= div_negate;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= div_valid ? div_rs1 : rs1;
      reg_q.rs2_val       <= div_valid ? div_rs2 : rs2;
      // Misaligned transfers trap and continue at the fall-through PC.
      reg_q.pc_next       <= resolved_taken ? jump_target : fallthrough;
      reg_q.late_branch   <= late_compare;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_index  <= in.pc[7:2] ^ in.pc[13:8];
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
    end

    if (reset)
      reg_q.valid <= 1'b0;
    else if (!stall)
      reg_q.valid <= in.valid && !div_wait;
  end

  assign out = reg_q;

endmodule
