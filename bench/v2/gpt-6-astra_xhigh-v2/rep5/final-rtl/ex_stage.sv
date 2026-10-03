// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   bit 0 = ID/EX register value (no forward)
//   bit 1 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   bit 2 = MEM/WB ALU result
//   bit 3 = MEM/WB load result
// The four enables are registered and mutually exclusive. Write permission
// is checked separately and can replay the consumer, never alter its masks.
//
// Latency:        1 cycle normally; MUL uses two, DIV/REM eight service cycles,
//                 including capture and EX/MEM acceptance, plus bus stalls.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [3:0]         fwd_rs1_sel,
  input  logic [3:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_wb_alu,    // MEM/WB.alu_result
  input  logic [31:0]        fwd_wb_load,   // MEM/WB.read_data
  input  logic               prediction_failed,
  output ex_mem_t  out,
  output logic               execute_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_train,
  output logic [5:0]         branch_index,
  output logic               branch_outcome
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    rs1 = (in.rs1_val & {32{fwd_rs1_sel[0]}}) |
          (fwd_ex_mem & {32{fwd_rs1_sel[1]}}) |
          (fwd_wb_alu & {32{fwd_rs1_sel[2]}}) |
          (fwd_wb_load & {32{fwd_rs1_sel[3]}});
    rs2 = (in.rs2_val & {32{fwd_rs2_sel[0]}}) |
          (fwd_ex_mem & {32{fwd_rs2_sel[1]}}) |
          (fwd_wb_alu & {32{fwd_rs2_sel[2]}}) |
          (fwd_wb_load & {32{fwd_rs2_sel[3]}});
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    // Fold PC/immediate substitution into the one-hot source enables.
    // Raw sources stay separate for RVFI, branches, stores, JALR and M.
    alu_a = ((in.rs1_val & {32{fwd_rs1_sel[0] && !in.ctrl.is_auipc}}) |
             (fwd_ex_mem & {32{fwd_rs1_sel[1] && !in.ctrl.is_auipc}})) |
            ((fwd_wb_alu & {32{fwd_rs1_sel[2] && !in.ctrl.is_auipc}}) |
             (fwd_wb_load & {32{fwd_rs1_sel[3] && !in.ctrl.is_auipc}})) |
             (in.pc & {32{in.ctrl.is_auipc}});
    alu_b = ((in.rs2_val & {32{fwd_rs2_sel[0] && !in.ctrl.alu_src}}) |
             (fwd_ex_mem & {32{fwd_rs2_sel[1] && !in.ctrl.alu_src}})) |
            ((fwd_wb_alu & {32{fwd_rs2_sel[2] && !in.ctrl.alu_src}}) |
             (fwd_wb_load & {32{fwd_rs2_sel[3] && !in.ctrl.alu_src}})) |
             (in.imm & {32{in.ctrl.alu_src}});
  end

  logic [31:0] alu_result;
  alu #(.COMBINATIONAL_DIV(1'b0), .COMBINATIONAL_MUL(1'b0)) u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  logic is_div, div_start, div_busy, div_valid;
  logic is_mul, mul_start, mul_busy, mul_valid, is_m;
  logic operands_invalid, replay;
  logic [31:0] div_result, mul_result, m_rs1_q, m_rs2_q;
  assign is_div = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign div_start = is_div && !div_busy && !stall && !prediction_failed && !reset;
  assign is_mul = in.valid && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  assign is_m = is_div || is_mul;
  assign mul_start = is_mul && !mul_busy && !stall && !prediction_failed && !reset;
  // Verify before M launch only: its operand snapshots survive all later
  // producer movement. An older memory hold defers correction; reset wins.
  assign operands_invalid = in.valid && prediction_failed && !div_busy && !mul_busy;
  assign replay = operands_invalid && !stall && !reset;
  assign execute_wait = !operands_invalid &&
                        ((is_div && !div_valid) || (is_mul && !mul_valid));

  div_unit u_div (
    .clock(clock), .reset(reset), .start(div_start),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .busy(div_busy), .result_valid(div_valid), .result(div_result),
    .result_accept(is_div && div_valid && !stall)
  );

  mul_unit u_mul (
    .clock(clock), .reset(reset), .start(mul_start),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .busy(mul_busy), .result_valid(mul_valid), .result(mul_result),
    .result_accept(is_mul && mul_valid && !stall)
  );

  // ID/EX holds the original instruction/metadata throughout execution.
  // Capture post-forward values before the older producers drain away.
  always_ff @(posedge clock) begin
    if (reset) begin
      m_rs1_q <= '0;
      m_rs2_q <= '0;
    end else if (div_start || mul_start) begin
      m_rs1_q <= rs1;
      m_rs2_q <= rs2;
    end
  end

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

  logic actual_taken, ex_advance;
  assign actual_taken = !in.ctrl.is_illegal && !misalign_fault &&
                        (branch_taken || in.ctrl.is_jump);
  assign ex_advance = in.valid && !stall && !execute_wait && !operands_invalid && !reset;
  // The exact fetched instruction supplied the predicted direct target.
  // Only direction needs checking; JALR always arrives predicted false.
  assign redirect = replay || (ex_advance && (actual_taken != in.predicted_taken));
  assign redirect_target = replay ? in.pc : !actual_taken ? (in.pc + 32'd4)
                         : in.ctrl.is_jump ? jump_target : branch_target;
  assign branch_train = ex_advance && in.ctrl.is_branch &&
                        !in.ctrl.is_illegal && !misalign_fault;
  assign branch_index = in.pc[7:2];
  assign branch_outcome = branch_taken;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (operands_invalid || execute_wait || !in.valid) begin
      // The old EX/MEM entry was consumed. Clear controls as well as
      // valid: memory requests and forwarding also inspect the controls.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= is_div ? div_result :
                            is_mul ? mul_result :
                            in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_m ? m_rs1_q : rs1;
      reg_q.rs2_val       <= is_m ? m_rs2_q : rs2;
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
