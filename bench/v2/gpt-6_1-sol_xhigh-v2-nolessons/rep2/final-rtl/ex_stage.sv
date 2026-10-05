// rtl/ex_stage.sv
//
// Execute stage. Uses finalized ID/EX operands, runs the ALU, resolves
// branches and computes the redirect target. Owns EX/MEM and exposes its
// current architectural result only toward ID's next operand capture.
//
// Latency:        1 cycle except division; EX/MEM drains bubbles while waiting.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic               producer_w_en,
  output logic [31:0]        producer_data,
  output logic               div_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               predictor_update_en,
  output logic [31:0]        predictor_update_pc,
  output logic               predictor_update_branch,
  output logic               predictor_update_jump,
  output logic               predictor_update_legal,
  output logic               predictor_update_taken,
  output logic [31:0]        predictor_update_target
);

  // ID/EX is the execute launch boundary; no late operand bypass exists.
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic is_div, div_start, div_consume, div_busy, div_done;
  logic [31:0] div_rs1_q, div_rs2_q;

  assign is_div = in.valid && (in.ctrl.alu_op == ALU_DIV
                 || in.ctrl.alu_op == ALU_DIVU || in.ctrl.alu_op == ALU_REM
                 || in.ctrl.alu_op == ALU_REMU);
  assign div_start = is_div && !div_busy && !stall && !reset;
  assign div_consume = is_div && div_done && !stall && !reset;
  // Includes the launch cycle; release ID/EX only when EX/MEM accepts
  // the completed result. The older pipeline drains while EX waits.
  assign div_wait = is_div && !div_consume;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .clock(clock), .reset(reset),
    .div_start(div_start), .div_consume(div_consume),
    .div_busy(div_busy), .div_done(div_done),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .mul_a ($signed({in.mul_sign_a, in.rs1_val})),
    .mul_b ($signed({in.mul_sign_b, in.rs2_val})),
    .out (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  // Eight unsigned four-bit leaves, then three balanced lexicographic
  // levels. Odd children hold the more significant group at every level.
  wire [15:1] compare_lt;
  wire [15:1] compare_eq;
  wire signed_lt;

  for (genvar g = 0; g < 8; g++) begin : g_compare_leaf
    assign compare_lt[8+g] = rs1[4*g +: 4] < rs2[4*g +: 4];
    assign compare_eq[8+g] = rs1[4*g +: 4] == rs2[4*g +: 4];
  end

  for (genvar g = 1; g < 8; g++) begin : g_compare_tree
    assign compare_lt[g] = compare_lt[2*g+1]
                           | (compare_eq[2*g+1] & compare_lt[2*g]);
    assign compare_eq[g] = compare_eq[2*g+1] & compare_eq[2*g];
  end

  assign signed_lt = (rs1[31] ^ rs2[31]) ? rs1[31] : compare_lt[1];

  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = compare_eq[1];
      BR_BNE:  branch_cond = !compare_eq[1];
      BR_BLT:  branch_cond = signed_lt;
      BR_BGE:  branch_cond = !signed_lt;
      BR_BLTU: branch_cond = compare_lt[1];
      BR_BGEU: branch_cond = !compare_lt[1];
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

  // Loads must wait for MEM extraction; unfinished division cannot supply
  // a result. Interlocks prevent ID capture during EX or memory holds.
  assign producer_w_en = in.valid && ctrl_with_trap.reg_write
                         && !ctrl_with_trap.is_illegal && (in.rd != 5'b0)
                         && !in.ctrl.mem_read && (!is_div || div_done);
  assign producer_data = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;

  logic ex_accept, actual_taken, direction_mismatch, target_mismatch;
  logic [31:0] actual_target, architectural_next_pc;

  assign ex_accept = in.valid && !stall && !div_wait && !reset;
  assign actual_taken = !ctrl_with_trap.is_illegal
                        && (branch_taken || in.ctrl.is_jump);
  assign actual_target = in.ctrl.is_jump ? jump_target : branch_target;
  assign architectural_next_pc = actual_taken ? actual_target : in.pc + 32'd4;
  // Compare direction separately. The target equality does not depend
  // on a branch-outcome-selected next-PC mux, and stale ordinary hits
  // recover to PC+4 just like incorrect taken branch predictions.
  assign direction_mismatch = in.predicted_taken != actual_taken;
  assign target_mismatch = in.predicted_taken && actual_taken
                           && (in.predicted_target != actual_target);
  assign redirect = ex_accept && (direction_mismatch || target_mismatch);
  assign redirect_target = architectural_next_pc;

  // Every accepted instruction also gets an opportunity to invalidate a
  // matching stale row. Holds and divider waits never train repeatedly.
  assign predictor_update_en = ex_accept;
  assign predictor_update_pc = in.pc;
  assign predictor_update_branch = in.ctrl.is_branch;
  assign predictor_update_jump = in.ctrl.is_jump;
  assign predictor_update_legal = !ctrl_with_trap.is_illegal;
  assign predictor_update_taken = actual_taken;
  assign predictor_update_target = actual_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_wait || !in.valid) begin
      // The previous EX/MEM instruction has just been consumed by MEM.
      // Clear every control field, including memory and forwarding enables.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= producer_data;
      reg_q.write_data    <= is_div ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div ? div_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= architectural_next_pc;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
