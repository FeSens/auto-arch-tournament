// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU or M-extension lane, and validates the oldest unissued PC.
// Owns the EX/MEM pipeline register.
//
// Forwarding selects from forward_unit are one-hot, in
// {EX/MEM result, MEM/WB write data, ID/EX register value} order.
//
// Latency:        1 cycle, plus one for MUL, two for high-half multiply,
//                 or eight for division and remainder.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               squash,        // registered recovery annuls ID/EX
  input  logic [31:0]        next_issue_pc,
  input  id_ex_t   in,
  input  logic [2:0]         fwd_rs1_sel,
  input  logic [2:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.write_result (registered)
  output ex_mem_t  out,
  output logic               ex_valid,
  output logic               m_wait,         // hold ID/EX until the M result
  output logic               reject_target,
  output logic               reject_sequential,
  output logic               train,
  output logic [31:2]        sequential_pc,
  output logic [31:2]        target_pc,
  output logic               resolved_take_target
);

  assign ex_valid = in.valid && !squash;

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = ({32{fwd_rs1_sel[2]}} & fwd_ex_mem) |
               ({32{fwd_rs1_sel[1]}} & fwd_mem_wb) |
               ({32{fwd_rs1_sel[0]}} & in.rs1_val);
  assign rs2 = ({32{fwd_rs2_sel[2]}} & fwd_ex_mem) |
               ({32{fwd_rs2_sel[1]}} & fwd_mem_wb) |
               ({32{fwd_rs2_sel[0]}} & in.rs2_val);

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_b;

  // Include immediate selection in the forwarding masks for the second operand.
  assign alu_b = ({32{!in.ctrl.alu_src && fwd_rs2_sel[2]}} & fwd_ex_mem) |
                 ({32{!in.ctrl.alu_src && fwd_rs2_sel[1]}} & fwd_mem_wb) |
                 ({32{!in.ctrl.alu_src && fwd_rs2_sel[0]}} & in.rs2_val) |
                 ({32{in.ctrl.alu_src}} & in.imm);

  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (rs1),
    .b   (alu_b),
    .out (alu_result)
  );

  logic        is_mul, mul_request, mul_request_ready, mul_result_valid;
  logic        is_div, div_request, div_request_ready, div_result_valid;
  logic        is_alu_result, m_active;
  logic [31:0] mul_result, div_result, m_rs1_q, m_rs2_q;

  assign is_mul = in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                  in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU;
  assign is_div = in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                  in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU;
  assign is_alu_result = !(is_mul || is_div || in.ctrl.is_jump || in.ctrl.is_auipc);
  assign m_active = ex_valid && !in.ctrl.is_illegal;
  assign mul_request = m_active && is_mul && !stall;
  assign div_request = m_active && is_div && !stall;
  assign m_wait = m_active && ((is_mul && !mul_result_valid) || (is_div && !div_result_valid));

  mul_unit u_mul (
    .clock         (clock),
    .reset         (reset),
    .request_valid (mul_request),
    .request_ready (mul_request_ready),
    .op            (in.ctrl.alu_op),
    .a             (rs1),
    .b             (rs2),
    .result_valid  (mul_result_valid),
    .result_ready  (mul_request),
    .result        (mul_result)
  );

  div_unit u_div (
    .clock         (clock),
    .reset         (reset),
    .request_valid (div_request),
    .request_ready (div_request_ready),
    .op            (in.ctrl.alu_op),
    .a             (rs1),
    .b             (rs2),
    .result_valid  (div_result_valid),
    .result_ready  (div_request),
    .result        (div_result)
  );

  // RVFI reports the same forwarded operands the unit captured, even
  // after older instructions drain and the forwarding muxes change.
  always_ff @(posedge clock) begin
    if ((mul_request && mul_request_ready) || (div_request && div_request_ready)) begin
      m_rs1_q <= rs1;
      m_rs2_q <= rs2;
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        take_target, misalign_fault, fence_i;
  logic        use_jalr, use_relative, target_match;
  logic        jalr_aligned, relative_aligned, jalr_match;
  logic        ex_advance, side_effects;
  logic [31:0] pc_plus4, relative_target;
  logic [31:0] rs1_plus_imm;
  logic [31:1] jalr_sum, jalr_carry, inverted_issue_pc;

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = (rs1 == rs2);
      BR_BNE:  branch_cond = (rs1 != rs2);
      BR_BLT:  branch_cond = ($signed(rs1) <  $signed(rs2));
      BR_BGE:  branch_cond = ($signed(rs1) >= $signed(rs2));
      BR_BLTU: branch_cond = (rs1 <  rs2);
      BR_BGEU: branch_cond = (rs1 >= rs2);
      default: branch_cond = 1'b0;
    endcase
  end

  // Compute the carry into the upper word-address bits in parallel with
  // the low increment. The link result and recovery share this value.
  assign pc_plus4        = {in.pc[31:18] + {13'b0, &in.pc[17:2]},
                            in.pc[17:2] + 16'd1, in.pc[1:0]};
  // AUIPC shares the PC-relative adder and leaves the forwarded ALU input direct.
  assign relative_target = in.pc + in.imm;
  assign rs1_plus_imm    = rs1 + in.imm;
  assign take_target     = in.ctrl.is_jump || (in.ctrl.is_branch && branch_cond);

  // A taken misaligned control transfer traps and resolves to PC+4.
  // JALR clears bit zero, so only bit one determines its alignment.
  assign jalr_aligned     = !rs1_plus_imm[1];
  assign relative_aligned = (relative_target[1:0] == 2'b00);
  assign use_jalr        = take_target && in.ctrl.is_jalr && jalr_aligned;
  assign use_relative    = take_target && !in.ctrl.is_jalr && relative_aligned;
  assign misalign_fault  = take_target && !resolved_take_target;

  // Recovery and predictor storage use word addresses after alignment checks.
  assign sequential_pc = pc_plus4[31:2];
  assign target_pc     = in.ctrl.is_jalr ? rs1_plus_imm[31:2] : relative_target[31:2];
  assign resolved_take_target = use_jalr || use_relative;

  // A sum equals the expected address when adding its bitwise complement
  // gives all ones. Carry-save compression then only needs complementary
  // sum and carry bits, with no carry propagation across the PC. JALR
  // discards bit zero, so assume the matching parity at that bit.
  assign inverted_issue_pc = ~next_issue_pc[31:1];
  assign jalr_sum = rs1[31:1] ^ in.imm[31:1] ^ inverted_issue_pc;
  assign jalr_carry[1] = rs1[0] & in.imm[0];
  assign jalr_carry[31:2] = (rs1[30:1] & in.imm[30:1]) |
                            ((rs1[30:1] | in.imm[30:1]) & inverted_issue_pc[30:1]);
  assign jalr_match = !next_issue_pc[0] && (&(jalr_sum ^ jalr_carry));

  // IF selects between the two comparisons after registering the direction.
  assign target_match     = in.ctrl.is_jalr ? jalr_match : (relative_target == next_issue_pc);
  assign fence_i          = !in.ctrl.is_illegal && {in.instr[14:12], in.instr[6:0]} == 10'b001_0001111;
  assign ex_advance       = ex_valid && !stall && !m_wait;
  assign side_effects     = ex_advance && !in.ctrl.is_illegal && !misalign_fault;
  assign reject_target    = ex_advance && (fence_i || !target_match);
  assign reject_sequential = ex_advance && (fence_i || pc_plus4 != next_issue_pc);
  assign train            = side_effects && (in.ctrl.is_branch || in.ctrl.is_jump);

  ctrl_t ctrl_out;
  always_comb begin
    ctrl_out = in.ctrl;
    ctrl_out.is_illegal = in.ctrl.is_illegal || misalign_fault;
    ctrl_out.reg_write  = in.ctrl.reg_write && side_effects;
    ctrl_out.mem_read   = in.ctrl.mem_read  && side_effects;
    ctrl_out.mem_write  = in.ctrl.mem_write && side_effects;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= ({32{is_alu_result}} & alu_result) |
                             ({32{in.ctrl.is_jump}} & pc_plus4) |
                             ({32{in.ctrl.is_auipc}} & relative_target) |
                             ({32{is_mul}} & mul_result) |
                             ({32{is_div}} & div_result);
      reg_q.eff_addr      <= rs1_plus_imm;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= (is_mul || is_div) ? m_rs1_q : rs1;
      reg_q.rs2_val       <= (is_mul || is_div) ? m_rs2_q : rs2;
      reg_q.pc_next       <= {resolved_take_target ? target_pc : sequential_pc, 2'b00};
      reg_q.ctrl          <= ctrl_out;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= ex_advance;
    end
  end

  assign out = reg_q;

endmodule
