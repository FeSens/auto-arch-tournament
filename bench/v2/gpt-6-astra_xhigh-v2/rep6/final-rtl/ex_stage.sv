// rtl/ex_stage.sv
//
// X consumes immutable resolved operands. Ordinary results bypass to D;
// M operations transfer partial arithmetic through the EX/MEM data flops.
//
// Latency:        1 cycle, or nine EX clocks for division when MEM is ready.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_mem_t  out,
  output logic               next_reg_write,
  output logic               result_pending,
  output logic [31:0]        ordinary_result,
  output logic               execute_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_update_valid,
  output logic [3:0]         branch_update_index,
  output logic               branch_update_agree
);

  // No live forwarding or ALU-input selection exists after ID/EX.
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  logic [31:0] alu_result;
  logic kill_ex;
  // The recovery edge may capture a speculative D head. Annul that X
  // slot while the repaired target is already at decode. Only actual
  // older memory backpressure holds this bit and the EX/MEM boundary.
  always_ff @(posedge clock) begin
    if (reset) kill_ex <= 1'b0;
    else if (!stall) kill_ex <= redirect;
  end
  logic is_div, is_mul, div_request, div_consume, div_busy, div_valid;
  div_token_t div_token;
  mul_partial_t mul_partial;
  assign is_mul = in.valid && !kill_ex && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  assign is_div = in.valid && !kill_ex && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign div_request = is_div && !div_busy && !stall && !reset;
  // div_valid is already asserted before complete-result transfer edge 8.
  // An actual MEM stall still holds the front end through hazard_unit;
  // otherwise this edge transfers the token and releases ID/EX together.
  assign div_consume = is_div && div_valid && !stall && !reset;
  assign execute_wait = is_div && !div_valid;
  // Pending eligibility must not depend on resolved branch/jump faults.
  assign result_pending = in.valid && !kill_ex && !in.ctrl.is_illegal
                        && in.ctrl.reg_write && (in.ctrl.mem_read || is_mul || is_div);
  assign ordinary_result = in.ctrl.is_jump ? in.pc + 32'd4 : alu_result;
  alu u_alu (
    .clock (clock),
    .reset (reset),
    .div_request (div_request),
    .div_consume (div_consume),
    .div_busy (div_busy),
    .div_valid (div_valid),
    .div_token (div_token),
    .mul_partial (mul_partial),
    .op  (in.ctrl.alu_op),
    .a   (in.alu_a),
    .b   (in.alu_b),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] jalr_sum;  // full byte address; only JALR clears bit 0

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
  logic misalign_jump;
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  logic ex_advance, actual_taken;
  logic [31:0] resolved_pc_next;
  // Current X writer eligibility, including immediate target-fault suppression.
  assign next_reg_write = in.valid && !kill_ex && ctrl_with_trap.reg_write && !ctrl_with_trap.is_illegal;
  assign ex_advance = !reset && !stall && !execute_wait && !kill_ex;
  assign actual_taken = !in.ctrl.is_illegal && !misalign_fault
                      && (branch_taken || in.ctrl.is_jump);
  assign resolved_pc_next = actual_taken
                          ? (in.ctrl.is_jump ? jump_target : branch_target)
                          : in.pc + 32'd4;
  assign redirect = in.valid && ex_advance && (actual_taken ^ in.predicted_taken);
  assign redirect_target = resolved_pc_next;
  // Exactly one update per advancing, non-faulting conditional branch.
  // Jumps, bubbles, memory holds, and outstanding divides never train.
  assign branch_update_valid = in.valid && ex_advance && in.ctrl.is_branch
                             && !in.ctrl.is_illegal && !misalign_fault;
  assign branch_update_index = in.pc[5:2];
  assign branch_update_agree = branch_cond == in.instr[31];

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  logic [31:0] effective_addr_q;

  // ID/EX itself preserves the divide's exact captured source metadata
  // throughout all rounds and completion holds, even after W drains.
  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= ordinary_result;
      reg_q.mul_partial   <= mul_partial;
      reg_q.div_token     <= div_token;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= resolved_pc_next;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.instr         <= in.instr;
    end
    if (reset) begin
      reg_q.ctrl <= '0;
      reg_q.m_kind <= M_NONE;
      reg_q.valid <= 1'b0;
    end else if (!stall) begin
      reg_q.ctrl <= (kill_ex || execute_wait || !in.valid) ? '0 : ctrl_with_trap;
      reg_q.m_kind <= (kill_ex || execute_wait || !in.valid) ? M_NONE
                      : is_div ? M_DIV : is_mul ? M_MUL : M_NONE;
      reg_q.valid <= in.valid && !execute_wait && !kill_ex;
    end
  end

  // Address transport shares the EX/MEM boundary but only the dmem hold.
  // Bubbles and divides may capture unused sums while memory controls are
  // inert. Keep the full sum: clearing JALR's bit 0 would corrupt byte ops.
  always_ff @(posedge clock) begin
    if (reset) effective_addr_q <= 32'b0;
    else if (!stall) effective_addr_q <= jalr_sum;
  end

  assign reg_q.effective_addr = effective_addr_q;
  assign out = reg_q;

endmodule
