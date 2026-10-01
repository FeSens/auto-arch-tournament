// rtl/ex_stage.sv
//
// Execute stage. Resolves the immediate EX/MEM operand forwarding muxes,
// runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX captured value
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // Forward-match bits in the ID/EX bundle are consumed by the top-level
  // forward_unit; EX receives their selected source through fwd_rs*_sel.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               predictor_update,
  output logic [2:0]         predictor_update_index,
  output logic               predictor_update_taken,
  output logic               divide_wait,
  output logic               multiply_wait
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    rs1 = (fwd_rs1_sel == 2'd1) ? fwd_ex_mem : in.rs1_val;
    rs2 = (fwd_rs2_sel == 2'd1) ? fwd_ex_mem : in.rs2_val;
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic        divide_op;
  logic        divider_start;
  logic        divider_consume;
  logic        divider_busy;
  logic        divider_done;
  logic [31:0] divider_result;
  logic [31:0] divide_rs1_q;
  logic [31:0] divide_rs2_q;
  logic        multiply_op;
  logic        multiplier_start;
  logic        multiplier_consume;
  logic        multiplier_busy;
  logic        multiplier_done;
  logic [31:0] multiplier_result;
  logic [31:0] multiply_rs1_q;
  logic [31:0] multiply_rs2_q;

  always_comb begin
    divide_op = in.valid &&
                (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU ||
                 in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
    multiply_op = in.valid &&
                  (in.ctrl.alu_op == ALU_MUL    || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU  || in.ctrl.alu_op == ALU_MULHSU);
`ifdef RISCV_FORMAL_ALTOPS
    // Keep the fast formal abstraction single-cycle; ALU M-ops use the
    // matching riscv-formal stand-ins in this build mode.
    divide_wait    = 1'b0;
    divider_start  = 1'b0;
    divider_consume = 1'b0;
    multiply_wait     = 1'b0;
    multiplier_start  = 1'b0;
    multiplier_consume = 1'b0;
`else
    divide_wait     = divide_op && !divider_done;
    divider_start   = divide_op && !divider_busy && !divider_done;
    divider_consume = divide_op && divider_done && !stall;
    multiply_wait     = multiply_op && !multiplier_done;
    multiplier_start  = multiply_op && !multiplier_busy && !multiplier_done;
    multiplier_consume = multiply_op && multiplier_done && !stall;
`endif
  end

  iterative_divider u_divider (
    .clock         (clock),
    .reset         (reset),
    .start         (divider_start),
    .signed_op     (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM),
    .remainder_op  (in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU),
    .dividend      (alu_a),
    .divisor       (alu_b),
    .consume       (divider_consume),
    .busy          (divider_busy),
    .done          (divider_done),
    .result        (divider_result)
  );

  iterative_multiplier u_multiplier (
    .clock      (clock),
    .reset      (reset),
    .start      (multiplier_start),
    .op         (in.ctrl.alu_op),
    .operand_a  (alu_a),
    .operand_b  (alu_b),
    .consume    (multiplier_consume),
    .busy       (multiplier_busy),
    .done       (multiplier_done),
    .result     (multiplier_result)
  );

  // RVFI must report the actual forwarded values consumed by the divide,
  // even though ID/EX remains held long enough for those forwarding
  // sources to drain before the instruction enters EX/MEM.
  always_ff @(posedge clock) begin
    if (reset) begin
      divide_rs1_q <= 32'b0;
      divide_rs2_q <= 32'b0;
      multiply_rs1_q <= 32'b0;
      multiply_rs2_q <= 32'b0;
    end else if (divider_start) begin
      divide_rs1_q <= rs1;
      divide_rs2_q <= rs2;
    end else if (multiplier_start) begin
      multiply_rs1_q <= rs1;
      multiply_rs2_q <= rs2;
    end
  end

  alu u_alu (
    .op         (in.ctrl.alu_op),
    .a          (alu_a),
    .b          (alu_b),
    .mul_result (multiplier_result),
    .div_result (divider_result),
    .out        (alu_result)
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

  logic [31:0] resolved_branch_next;
  logic        branch_mispredict;

  always_comb begin
    // A misaligned taken branch traps in this core and retires with the
    // sequential PC as pc_wdata, so recovery must use that same next PC.
    resolved_branch_next = (branch_taken && !misalign_branch)
                         ? branch_target : (in.pc + 32'd4);
    // A predicted-taken target is formed from this same instruction's
    // immediate, so target equality is guaranteed. Only direction can
    // differ, except a predicted-taken misaligned target: this core traps
    // that branch and resumes at pc+4.
    branch_mispredict = in.ctrl.is_branch
                     && (branch_taken && !misalign_branch
                         ? !in.pred_taken : in.pred_taken);
    redirect = (branch_mispredict || in.ctrl.is_jump) && !misalign_jump;
    if (in.ctrl.is_jump)
      redirect_target = jump_target;
    else
      redirect_target = resolved_branch_next;
    predictor_update = in.valid && in.ctrl.is_branch && !stall
                    && !divide_wait && !multiply_wait;
    predictor_update_index = in.pc[4:2];
    predictor_update_taken = branch_taken;
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
    end else if (divide_wait || multiply_wait) begin
      // The older EX/MEM entry advances normally on the first arithmetic
      // wait cycle; subsequent cycles carry bubbles while EX holds the
      // divide or multiply in ID/EX.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= (divide_op && divider_done) ? divide_rs2_q
                                : (multiply_op && multiplier_done) ? multiply_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= (divide_op && divider_done) ? divide_rs1_q
                                : (multiply_op && multiplier_done) ? multiply_rs1_q : rs1;
      reg_q.rs2_val       <= (divide_op && divider_done) ? divide_rs2_q
                                : (multiply_op && multiplier_done) ? multiply_rs2_q : rs2;
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
