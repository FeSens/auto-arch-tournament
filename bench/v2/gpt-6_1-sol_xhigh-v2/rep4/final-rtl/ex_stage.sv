// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (registered alongside ID/EX by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB final selected result (instruction two ahead)
//
// Latency:        1 cycle (EX/MEM register clocked here).
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
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB selected result (registered)
  input  logic               mem_is_multiply,
  input  logic [31:0]        mem_multiply_result, // RVFI metadata only
  output ex_mem_t  out,
  output logic               next_w_en,     // valid, post-trap EX write eligibility
  output logic               divider_wait,
  output logic               redirect,
  output logic               direct_redirect,
  output logic [31:0]        redirect_target,
  output logic               indirect_landing_q,
  output logic [31:0]        indirect_target_q
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
  logic is_divide, div_launch, div_consume, div_busy, div_result_valid;
  // Divider operands must survive disappearing bypass sources while waiting.
  logic [31:0] div_rs1_q, div_rs2_q;
  assign is_divide = in.valid && !in.ctrl.is_illegal && (in.ctrl.alu_op == ALU_DIV ||
                     in.ctrl.alu_op == ALU_DIVU || in.ctrl.alu_op == ALU_REM ||
                     in.ctrl.alu_op == ALU_REMU);
  assign div_launch = is_divide && !div_busy && !div_result_valid && !stall && !reset;
  assign div_consume = is_divide && div_result_valid && !stall && !reset;
  assign divider_wait = is_divide && !div_result_valid;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_launch) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock(clock), .reset(reset),
    .mul_launch(1'b0), .mul_consume(1'b0),
    /* verilator lint_off PINCONNECTEMPTY */
    .mul_busy(), .mul_result_valid(),
    /* verilator lint_on PINCONNECTEMPTY */
    .div_launch(div_launch), .div_consume(div_consume),
    .div_busy(div_busy), .div_result_valid(div_result_valid),
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
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

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
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : (in.pc + in.imm);
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  logic misalign_branch;
  logic misalign_direct;
  logic misalign_indirect;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    // Keep indirect forwarded operands outside direct recovery eligibility.
    misalign_direct = misalign_branch ||
                      (in.ctrl.is_jump && !in.ctrl.is_jalr &&
                       (branch_target[1:0] != 2'b00));
    misalign_indirect = in.ctrl.is_jump && in.ctrl.is_jalr && jalr_sum[1];
    misalign_fault  = misalign_direct || misalign_indirect;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // When ID/EX admits a new payload, this producer advances to EX/MEM.
  // The shared downstream hold prevents capture while EX cannot advance.
  assign next_w_en = in.valid && ctrl_with_trap.reg_write;

  // Direct direction recovery stays on the resolving edge, but its PC is
  // already selected in ID. JALR squashes on that same edge and registers
  // its full forwarded target for the following cycle's bus-address bypass.
  logic direct_taken, control_accept, indirect_accept;
  // Alignment depends only on the direct target's low bits. Qualifying
  // direction here avoids feeding the comparison into its own trap guard.
  assign direct_taken = (branch_target[1:0] == 2'b00) && !in.ctrl.is_illegal &&
                        (branch_taken || (in.ctrl.is_jump && !in.ctrl.is_jalr));
  assign control_accept = in.valid && !reset && !stall && !divider_wait;
  assign direct_redirect = control_accept && (direct_taken ^ in.predicted_taken);
  assign indirect_accept = control_accept && in.ctrl.is_jalr &&
                           !misalign_indirect && !in.ctrl.is_illegal;
  assign redirect = direct_redirect || indirect_accept;
  assign redirect_target = in.direct_recovery_pc;

  always_ff @(posedge clock) begin
    if (reset) begin
      indirect_landing_q <= 1'b0;
      indirect_target_q <= 32'b0;
    end else begin
      // Landing is one cycle even if instruction memory is unready.
      indirect_landing_q <= indirect_accept;
      if (indirect_accept) indirect_target_q <= {jalr_sum[31:1], 1'b0};
    end
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (divider_wait) begin
      // Older instructions drain once while ID/EX holds the M request.
      // Only a genuine dmem stall above retains an EX/MEM request.
      reg_q.valid <= 1'b0;
    end else begin
      // No operation/result selection precedes the dedicated LSU register.
      reg_q.effective_addr <= rs1 + in.imm;
      reg_q.multiply_a    <= rs1;
      reg_q.multiply_b    <= rs2;
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). MEM selects loads before its
      // register edge, so we route the link result here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // Raw source fields are reported even for unused instruction aliases.
      // True multiply consumers replay through MEM/WB; only verification
      // metadata sees this MEM product, never functional execution operands.
      reg_q.rs1_val       <= is_divide ? div_rs1_q
                            : (mem_is_multiply && fwd_rs1_sel == 2'd1)
                              ? mem_multiply_result : rs1;
      reg_q.rs2_val       <= is_divide ? div_rs2_q
                            : (mem_is_multiply && fwd_rs2_sel == 2'd1)
                              ? mem_multiply_result : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
