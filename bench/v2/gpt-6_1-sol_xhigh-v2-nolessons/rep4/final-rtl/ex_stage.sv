// rtl/ex_stage.sv
//
// Execute directly from registered OC/EX operands, resolve branches and
// export the current result only to the following OC capture mux.
// Runs the ALU and computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// No forwarding mux precedes any current EX arithmetic.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               squash,        // older registered MEM/WB repair
  input  oc_ex_t   in,
  output ex_mem_t  out,
  output logic               bypass_w_en,   // valid post-target-trap writer
  output logic               bypass_ready,
  output logic [31:0]        bypass_value,
  output logic               divider_wait,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               branch_train_en,
  output logic [5:0]         branch_train_index,
  output logic               branch_train_taken
);

  // ── Registered architectural sources ─────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  assign alu_a = in.alu_a_val;
  assign alu_b = in.alu_b_val;

  logic [31:0] alu_result;
  logic [31:0] predicted_product;
  logic [31:0] div_result;
  logic div_busy, div_result_valid, div_start, div_consume, is_div, is_mul;
  ex_mem_t div_payload_q;
  ex_mem_t exec_payload;

  assign is_div = in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                  in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU;
  assign is_mul = in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                  in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU;
  assign div_start = in.valid && is_div && !stall && !squash && !div_busy;
  assign div_consume = div_busy && div_result_valid && !stall && !squash;
  // Release OC/EX on the very edge that accepts the result. busy stays
  // asserted through that edge, preventing the held instruction restarting.
  assign divider_wait = !squash && (div_busy || (in.valid && is_div)) && !div_consume;

  mul_predictor u_mul_predictor (
    .op (in.ctrl.alu_op),
    .a (rs1),
    .b (rs2),
    .out (predicted_product)
  );

  alu #(.FULL_MUL_ENABLED(1'b0)) u_alu (
    .clock (clock),
    .reset (reset),
    .cancel (squash),
    .start (div_start),
    .consume (div_consume),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result),
    .busy (div_busy),
    .result_valid (div_result_valid),
    .div_result (div_result)
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
    branch_taken  = in.valid && in.ctrl.is_branch && branch_cond;
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
    misalign_jump   = in.valid && in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  logic [31:0] effective_addr;
  logic access_fault;
  assign effective_addr = rs1 + in.imm;
  // Loads that will trap do not shadow an older valid writer in OC.
  assign access_fault = (in.ctrl.mem_read || in.ctrl.mem_write) &&
                        ((in.ctrl.mem_width == 2'd2 && effective_addr[1:0] != 0) ||
                         (in.ctrl.mem_width == 2'd1 && effective_addr[0]));
  assign bypass_w_en = in.valid && in.rd != 0 && in.ctrl.reg_write &&
                       !in.ctrl.is_illegal && !misalign_jump &&
                       !(in.ctrl.mem_read && access_fault) && !squash;
  assign bypass_ready = bypass_w_en && !in.ctrl.mem_read &&
                        (!is_div || div_result_valid);
  assign bypass_value = in.ctrl.is_jump ? in.pc + 32'd4 :
                        is_mul ? predicted_product : alu_result;

  logic actual_taken;
  assign actual_taken = branch_taken && !misalign_fault && !in.ctrl.is_illegal;
  // Conditional recovery compares direction only. Direct JAL targets
  // were predicted exactly; JALR uses its registered architectural source.
  assign redirect = in.valid && !stall && !squash && !divider_wait && !in.ctrl.is_illegal &&
                    ((in.ctrl.is_branch && (actual_taken ^ in.predicted_taken)) ||
                     (in.ctrl.is_jalr && !misalign_fault));
  assign redirect_target = in.ctrl.is_jalr ? jump_target
                         : actual_taken ? branch_target : in.pc + 32'd4;

  // Train once on EX advancement, never while its instruction is held.
  // A misaligned branch target is excluded even when the condition is false.
  assign branch_train_en = in.valid && in.ctrl.is_branch && !in.ctrl.is_illegal &&
                           branch_target[1:0] == 2'b00 && !stall && !squash && !divider_wait;
  assign branch_train_index = in.pc[7:2];
  assign branch_train_taken = actual_taken;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_comb begin
    exec_payload = '0;
    if (in.valid) begin
      exec_payload.pc            = in.pc;
      exec_payload.alu_result    = in.ctrl.is_jump ? (in.pc + 32'd4)
                                   : is_mul ? predicted_product : alu_result;
      exec_payload.effective_addr = effective_addr;
      exec_payload.write_data    = rs2;
      exec_payload.rd            = in.rd;
      exec_payload.rs1_addr      = in.rs1_addr;
      exec_payload.rs2_addr      = in.rs2_addr;
      exec_payload.rs1_val       = rs1;
      exec_payload.rs2_val       = rs2;
      exec_payload.pc_next       = misalign_fault   ? (in.pc + 32'd4)
                                   : in.ctrl.is_jump ? jump_target
                                   : branch_taken    ? branch_target
                                                     : (in.pc + 32'd4);
      exec_payload.branch_taken  = branch_taken;
      exec_payload.branch_target = branch_target;
      exec_payload.ctrl          = ctrl_with_trap;
      exec_payload.instr         = in.instr;
      exec_payload.valid         = 1'b1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
      div_payload_q <= '0;
    end else if (squash) begin
      reg_q <= '0;
      div_payload_q <= '0;
    end else begin
      if (div_start) div_payload_q <= exec_payload;
      if (!stall) begin
        if (div_consume) begin
          reg_q <= div_payload_q;
          reg_q.alu_result <= div_result;
        end else if (divider_wait) begin
          // MEM may drain while EX computes. Never replay an older
          // load/store or expose stale forwarding/side-effect controls.
          reg_q <= '0;
        end else begin
          reg_q <= exec_payload;
        end
      end
    end
  end

  assign out = reg_q;

endmodule
