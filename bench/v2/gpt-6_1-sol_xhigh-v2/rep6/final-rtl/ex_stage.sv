// rtl/ex_stage.sv
//
// Execute stage. Consumes the resolved architectural operands and final
// ALU inputs registered in ID/EX, runs the ALU, and resolves branches.
// Exports the advancing architectural result to younger ID before the
// EX/MEM register hold/bubble selection. Owns that pipeline register.
//
// Latency:        1 cycle ordinarily; multiply takes 2 cycles; division
//                 blocks until its registered
//                 result can transfer to EX/MEM (35 cycles after launch).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic [31:0]        bypass_data,
  output logic [4:0]         bypass_rd,
  output logic               bypass_w_en,
  output logic               busy,          // hold IF and ID/EX, drain MEM/WB
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_update,
  output logic [6:0]         branch_index,
  output logic               branch_outcome
);

  // Architectural consumers use only registered source values.
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  logic [31:0] alu_result;
  alu u_alu (
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
    branch_target = in.direct_target;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : in.direct_target;
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

  logic actual_nonsequential, ex_advance;
  logic [31:0] sequential_pc;
  assign sequential_pc = in.pc + 32'd4;
  assign ex_advance = in.valid && !reset && !stall && !busy;
  assign actual_nonsequential = !in.ctrl.is_illegal && !misalign_fault
                               && (branch_taken || in.ctrl.is_jump);
  // Direct predictions carry the same instruction-derived target used
  // here. Direction XOR suffices; unpredicted aligned JALR also corrects.
  assign redirect = ex_advance && (actual_nonsequential ^ in.predicted_taken);
  assign redirect_target = actual_nonsequential
                           ? (in.ctrl.is_jump ? jump_target : branch_target)
                           : sequential_pc;
  assign branch_update = ex_advance && in.ctrl.is_branch
                         && !in.ctrl.is_illegal && branch_target[1:0] == 2'b00;
  assign branch_index = in.pc[8:2];
  assign branch_outcome = branch_taken;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t execute_payload;
  ex_mem_t divide_payload_q;
  ex_mem_t multiply_payload_q;
  logic is_divide, div_req_ready, div_result_valid;
  logic div_launch, div_transfer;
  logic [31:0] div_result;
  logic is_multiply, mul_req_ready, mul_result_valid;
  logic mul_launch, mul_transfer;
  logic [31:0] mul_result;

  // Occupancy depends only on the decoded operation, never on branch
  // operand comparisons. Acceptance still uses the final legal controls.
  assign is_divide = (in.ctrl.alu_op == ALU_DIV) ||
                     (in.ctrl.alu_op == ALU_DIVU) ||
                     (in.ctrl.alu_op == ALU_REM) ||
                     (in.ctrl.alu_op == ALU_REMU);
  assign is_multiply = (in.ctrl.alu_op == ALU_MUL) ||
                          (in.ctrl.alu_op == ALU_MULH) ||
                          (in.ctrl.alu_op == ALU_MULHU) ||
                          (in.ctrl.alu_op == ALU_MULHSU);
  assign busy = in.valid && !reset
                && ((is_divide && !div_result_valid)
                    || (is_multiply && !mul_result_valid));
  assign div_launch = in.valid && is_divide && !reset && !stall && div_req_ready
                      && ctrl_with_trap.reg_write && !ctrl_with_trap.is_illegal;
  assign div_transfer = in.valid && is_divide && !reset && !stall
                        && div_result_valid && divide_payload_q.valid
                        && divide_payload_q.ctrl.reg_write
                        && !divide_payload_q.ctrl.is_illegal;
  assign mul_launch = in.valid && is_multiply && !reset && !stall && mul_req_ready
                      && ctrl_with_trap.reg_write && !ctrl_with_trap.is_illegal;
  assign mul_transfer = in.valid && is_multiply && !reset && !stall
                        && mul_result_valid && multiply_payload_q.valid
                        && multiply_payload_q.ctrl.reg_write
                        && !multiply_payload_q.ctrl.is_illegal;

  mul_unit u_mul (
    .clock (clock), .reset (reset),
    .req_valid (mul_launch), .req_ready (mul_req_ready),
    .req_op (in.ctrl.alu_op), .req_a (in.alu_a), .req_b (in.alu_b),
    .result_valid (mul_result_valid), .result_ready (mul_transfer),
    .result (mul_result)
  );

  div_unit u_div (
    .clock (clock), .reset (reset),
    .req_valid (div_launch), .req_ready (div_req_ready),
    .req_op (in.ctrl.alu_op), .req_a (rs1), .req_b (rs2),
    .result_valid (div_result_valid), .result_ready (div_transfer),
    .result (div_result)
  );

  always_comb begin
    execute_payload = '0;
    execute_payload.pc = in.pc;
    execute_payload.alu_result = in.ctrl.is_jump ? sequential_pc : alu_result;
    execute_payload.write_data = rs2;
    execute_payload.rd = in.rd;
    execute_payload.rs1_addr = in.rs1_addr;
    execute_payload.rs2_addr = in.rs2_addr;
    execute_payload.rs1_val = rs1;
    execute_payload.rs2_val = rs2;
    execute_payload.pc_next = actual_nonsequential
                            ? (in.ctrl.is_jump ? jump_target : branch_target)
                            : sequential_pc;
    execute_payload.branch_taken = branch_taken;
    execute_payload.branch_target = branch_target;
    execute_payload.ctrl = ctrl_with_trap;
    execute_payload.instr = in.instr;
    execute_payload.valid = in.valid;
  end

  // Forward only an actual EX advance, using final trap-adjusted writes.
  // Loads have only an effective address here; their value comes from MEM.
  // Accepted arithmetic responses use the saved launch metadata and result.
  assign bypass_data = is_multiply ? mul_result
                     : is_divide ? div_result : execute_payload.alu_result;
  assign bypass_rd = is_multiply ? multiply_payload_q.rd
                   : is_divide ? divide_payload_q.rd : in.rd;
  assign bypass_w_en = ex_advance && (bypass_rd != 5'b0)
                      && (is_multiply
                          ? (mul_transfer && multiply_payload_q.valid
                             && multiply_payload_q.ctrl.reg_write
                             && !multiply_payload_q.ctrl.is_illegal
                             && !multiply_payload_q.ctrl.mem_read)
                          : is_divide
                          ? (div_transfer && divide_payload_q.valid
                             && divide_payload_q.ctrl.reg_write
                             && !divide_payload_q.ctrl.is_illegal
                             && !divide_payload_q.ctrl.mem_read)
                          : (ctrl_with_trap.reg_write
                             && !ctrl_with_trap.is_illegal
                             && !ctrl_with_trap.mem_read));

  // Capture the registered operands and original instruction exactly once.
  // Older stages can drain without altering arithmetic or RVFI operands.
  always_ff @(posedge clock) begin
    if (reset) divide_payload_q <= '0;
    else if (div_launch) divide_payload_q <= execute_payload;
    else if (div_transfer) divide_payload_q <= '0;
  end

  always_ff @(posedge clock) begin
    if (reset) multiply_payload_q <= '0;
    else if (mul_launch) multiply_payload_q <= execute_payload;
    else if (mul_transfer) multiply_payload_q <= '0;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (mul_transfer) begin
      reg_q <= multiply_payload_q;
      reg_q.alu_result <= mul_result;
    end else if (div_transfer) begin
      reg_q <= divide_payload_q;
      reg_q.alu_result <= div_result;
    end else if (busy || !in.valid) begin
      // A wait consumes the older MEM instruction and inserts a bubble.
      // Clear the entire bundle, including all side-effect controls.
      reg_q <= '0;
    end else begin
      reg_q <= execute_payload;
    end
  end

  assign out = reg_q;

endmodule
