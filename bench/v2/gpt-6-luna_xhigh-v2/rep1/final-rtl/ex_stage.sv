// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU or shared iterative divider, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB result (instruction two ahead, post regfile-write mux)
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
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               loop_update_valid,
  output logic [31:0]        loop_update_pc,
  output logic               loop_update_taken,
  output logic               div_stall
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
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  logic        div_instruction;
  logic        div_start;
  logic        div_busy;
  logic        div_done;
  logic        div_wait;
  logic        div_signed;
  logic        div_remainder;
  logic [31:0] div_result;
  logic [31:0] ex_result;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;
  logic [31:0] ex_rs1;
  logic [31:0] ex_rs2;

  always_comb begin
    div_instruction = in.valid &&
                      (in.ctrl.alu_op == ALU_DIV  ||
                       in.ctrl.alu_op == ALU_DIVU ||
                       in.ctrl.alu_op == ALU_REM  ||
                       in.ctrl.alu_op == ALU_REMU);
    div_signed    = (in.ctrl.alu_op == ALU_DIV) ||
                    (in.ctrl.alu_op == ALU_REM);
    div_remainder = (in.ctrl.alu_op == ALU_REM) ||
                    (in.ctrl.alu_op == ALU_REMU);
  end

  shared_divider u_divider (
    .clock        (clock),
    .reset        (reset),
    .start        (div_start),
    .signed_op    (div_signed),
    .remainder_op (div_remainder),
    .dividend     (alu_a),
    .divisor      (alu_b),
    .busy         (div_busy),
    .done         (div_done),
    .result       (div_result)
  );

  // ALTOPS mode keeps the one-cycle algebraic stand-ins in alu.sv, as
  // expected by riscv-formal. In hardware, hold DIV/REM in EX until done.
`ifdef RISCV_FORMAL_ALTOPS
  assign div_start = 1'b0;
  assign div_wait  = 1'b0;
  assign ex_result = alu_result;
  assign ex_rs1    = rs1;
  assign ex_rs2    = rs2;
`else
  assign div_start = div_instruction && !div_busy && !div_done && !stall;
  assign div_wait  = div_instruction && !div_done;
  assign ex_result = (div_instruction && div_done) ? div_result : alu_result;
  assign ex_rs1    = (div_instruction && div_done) ? div_rs1_q : rs1;
  assign ex_rs2    = (div_instruction && div_done) ? div_rs2_q : rs2;

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_start) begin
      // Keep the forwarded source values alongside the divider state.
      // EX/MEM drains its older producer while the divide iterates, so
      // forwarding would otherwise disappear before the DIV retires.
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end
`endif

  assign div_stall = div_wait;

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic        branch_equal;
  logic        branch_unsigned_lt;
  logic        branch_signed_lt;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    // Share the wide comparisons across all six branch encodings. Signed
    // order differs from unsigned order only when the operands' signs differ.
    branch_equal      = (rs1 == rs2);
    branch_unsigned_lt = (rs1 < rs2);
    branch_signed_lt   = (rs1[31] != rs2[31]) ? rs1[31] : branch_unsigned_lt;

    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = branch_equal;
      BR_BNE:  branch_cond = !branch_equal;
      BR_BLT:  branch_cond = branch_signed_lt;
      BR_BGE:  branch_cond = !branch_signed_lt;
      BR_BLTU: branch_cond = branch_unsigned_lt;
      BR_BGEU: branch_cond = !branch_unsigned_lt;
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
  logic branch_mispredict;
  logic branch_redirect;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = in.ctrl.is_branch && branch_taken
                      && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;
    branch_mispredict = in.ctrl.is_branch &&
                        (branch_taken != in.pred_taken);
    // A predicted-taken branch to a misaligned target must also recover to
    // the architectural fall-through PC, even though the direction matched.
    branch_redirect = branch_mispredict ||
                      (misalign_branch && in.pred_taken);

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  assign redirect = (in.ctrl.is_jump && !misalign_jump) || branch_redirect;
  assign redirect_target = in.ctrl.is_jump ? jump_target :
                           ((misalign_branch || !branch_taken)
                            ? (in.pc + 32'd4) : branch_target);
  // Train once when the branch advances into EX/MEM; a data-memory stall
  // holds ID/EX and must not count the same resolution repeatedly.
  assign loop_update_valid = in.valid && in.ctrl.is_branch && in.imm[31] &&
                             !stall && !div_wait && !misalign_fault;
  assign loop_update_pc = in.pc;
  assign loop_update_taken = branch_taken;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_wait) begin
      // Let older EX/MEM work drain, then keep a bubble there while the
      // divider iterates. ID/EX retains this DIV/REM instruction.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : ex_result;
      reg_q.write_data    <= ex_rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= ex_rs1;
      reg_q.rs2_val       <= ex_rs2;
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
