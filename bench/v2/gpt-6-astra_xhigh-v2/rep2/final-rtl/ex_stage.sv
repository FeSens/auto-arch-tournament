// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB registered result (instruction two ahead)
//
// Latency:        1 cycle for base, 2 for multiply; divides hold ID/EX through
//                 eight internal clocks, then transfer once to EX/MEM
//                 on the next available edge (earliest edge nine).
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
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.wb_data (registered)
  output ex_mem_t  out,
  output logic               execute_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [5:0]         train_index,
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
  logic is_divide, div_req_valid, div_req_ready;
  logic div_result_valid, div_result_ready;
  logic is_multiply, mul_req_valid, mul_req_ready;
  logic mul_result_valid, mul_result_ready;
  logic [31:0] div_rs1_q, div_rs2_q;
  assign is_divide = (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                      in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign is_multiply = (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                        in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  assign execute_wait = in.valid && ((is_divide && !div_result_valid) ||
                                      (is_multiply && !mul_result_valid));
  assign div_req_valid = in.valid && is_divide && !stall && div_req_ready;
  assign div_result_ready = in.valid && is_divide && !stall;
  assign mul_req_valid = in.valid && is_multiply && !stall && mul_req_ready;
  assign mul_result_ready = in.valid && is_multiply && !stall;

  // Forwarding sources may drain during blocking execution. EX permits only
  // one operation, so multiply and divide share the saved RVFI operands.
  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= '0;
      div_rs2_q <= '0;
    end else if (div_req_valid || mul_req_valid) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end
  alu u_alu (
    .clock(clock), .reset(reset),
    .mul_req_valid(mul_req_valid), .mul_req_ready(mul_req_ready),
    .mul_result_valid(mul_result_valid), .mul_result_ready(mul_result_ready),
    .div_req_valid(div_req_valid), .div_req_ready(div_req_ready),
    .div_result_valid(div_result_valid), .div_result_ready(div_result_ready),
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
  logic [31:0] jalr_sum;  // full address sum; only JALR masks bit 0

  // Native two-bit leaves, then four balanced levels. In each pair the
  // odd child is more significant; its ordering wins unless it is equal.
  logic [31:1] branch_eq_tree, branch_lt_tree;
  logic equal, unsigned_less, signed_less;
  for (genvar k = 0; k < 16; k++) begin : branch_compare_leaves
    assign branch_eq_tree[16+k] = (rs1[2*k +: 2] == rs2[2*k +: 2]);
    assign branch_lt_tree[16+k] = (rs1[2*k +: 2] < rs2[2*k +: 2]);
  end
  for (genvar k = 1; k < 16; k++) begin : branch_compare_groups
    assign branch_eq_tree[k] = branch_eq_tree[2*k+1] && branch_eq_tree[2*k];
    assign branch_lt_tree[k] = branch_lt_tree[2*k+1] ||
                              (branch_eq_tree[2*k+1] && branch_lt_tree[2*k]);
  end
  assign equal = branch_eq_tree[1];
  assign unsigned_less = branch_lt_tree[1];
  assign signed_less = (rs1[31] ^ rs2[31]) ? rs1[31] : unsigned_less;

  always_comb begin
    branch_cond = ((in.branch_eq && equal) ||
                   (in.branch_signed && signed_less) ||
                   (in.branch_unsigned && unsigned_less)) ^ in.branch_invert;
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

  logic ex_accept, actual_taken, direct_control;
  assign ex_accept = !reset && in.valid && !stall && !execute_wait;
  assign actual_taken = (branch_taken || in.ctrl.is_jump) &&
                        !in.ctrl.is_illegal && !misalign_fault;
  assign direct_control = in.ctrl.is_branch ||
                          (in.ctrl.is_jump && !in.ctrl.is_jalr);
  assign redirect = ex_accept &&
                    ((direct_control && (in.predicted_taken != actual_taken)) ||
                     (in.ctrl.is_jalr && actual_taken));
  assign redirect_target = !actual_taken ? (in.pc + 32'd4)
                         : in.ctrl.is_jump ? jump_target : branch_target;

  // Only an accepted conditional branch trains, once, using its actual
  // condition. A not-taken branch with an unaligned encoded target has
  // no target fault and still trains; jumps and faulting branches do not.
  assign train_valid = ex_accept && in.ctrl.is_branch &&
                       !in.ctrl.is_illegal && !misalign_fault;
  assign train_index = in.pc[7:2];
  assign train_taken = branch_cond;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (execute_wait || !in.valid) begin
      // The older MEM operation advances on this edge. Clear all controls:
      // memory enables and forwarding also inspect fields besides valid.
      reg_q <= '0;
      // The unused arithmetic payload captures independently of bubble
      // control; every other field remains zero and cannot cause effects.
      reg_q.alu_result <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). MEM selects load data only for
      // LOADs before registering the WB result, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.effective_addr <= jalr_sum;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= (is_divide || is_multiply) ? div_rs1_q : rs1;
      reg_q.rs2_val       <= (is_divide || is_multiply) ? div_rs2_q : rs2;
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
