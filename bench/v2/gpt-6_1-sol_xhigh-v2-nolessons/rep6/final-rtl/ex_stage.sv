// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (driven by forward_unit):
//   00 = ID/EX register value (no forward)
//   01 = EX/MEM aluResult (instruction immediately ahead in MEM)
//   10 = MEM/WB registered architectural result
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               squash,        // older registered recovery kills current EX
  input  id_ex_t   in,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.wb_result (registered)
  output ex_mem_t  out,
  output logic               execute_hold,  // hold upstream only (divider)
  output predictor_train_t   train,
  output logic               redirect,
  output logic [31:0]        redirect_target
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
  alu #(.ENABLE_SHIFTS(1'b0)) u_alu (
    .op      (in.ctrl.alu_op),
    .a       (alu_a),
    .b       (alu_b),
    .mul_rs1 (rs1),
    .mul_rs2 (rs2),
    .out     (alu_result)
  );

`ifdef RISCV_FORMAL_ALTOPS
  // The exact algebraic DIV/REM substitutions retain single-cycle EX.
  assign execute_hold = 1'b0;
`else
  logic div_instruction, div_active_q;
  logic div_req_valid, div_req_ready, div_result_valid, div_result_ready, div_transfer, div_busy;
  logic [31:0] div_result;
  ex_mem_t div_metadata_q;

  assign div_instruction = in.valid && !in.ctrl.is_illegal &&
                           (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                            in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign div_req_valid = !reset && !squash && div_instruction && !div_active_q && !div_busy && !stall;
  // The payload-transfer predicate retains its original inputs. Squash
  // gates consumption and side-effect controls, never the wide D muxes.
  assign div_transfer = !reset && in.valid && div_active_q && !stall;
  assign div_result_ready = !squash && div_transfer;
  // Include the request cycle. On completion, release ID/EX on precisely
  // the edge that transfers the result into EX/MEM, so it cannot relaunch.
  assign execute_hold = !reset && !squash && ((div_instruction && !div_active_q) ||
                         (div_active_q && !(div_result_valid && div_transfer)));

  divider u_divider (
    .clock (clock), .reset (reset),
    .req_valid (div_req_valid), .req_ready (div_req_ready),
    .op (in.ctrl.alu_op), .a (rs1), .b (rs2),
    .busy (div_busy), .result_valid (div_result_valid),
    .result_ready (div_result_ready), .result (div_result)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      div_active_q <= 1'b0;
      div_metadata_q <= '0;
    end else if (div_req_valid && div_req_ready) begin
      div_active_q <= 1'b1;
      div_metadata_q <= normal_payload;
    end else if (div_result_valid && div_result_ready) begin
      div_active_q <= 1'b0;
    end
  end
`endif

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_base, branch_polarity, recovery_polarity, branch_mismatch;
  logic [3:0] lane_eq, lane_lt;
  logic [1:0] pair_eq, pair_lt;
  logic equal_operands, ordered_less;
  logic [7:0] ordered_top_rs1, ordered_top_rs2;
  logic advance_ex;
  logic recovery_valid, recovery_valid_q;
  logic [31:0] recovery_target, recovery_target_q;
  logic [31:0] conditional_repair_target;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  for (genvar lane = 0; lane < 4; lane++) begin : g_branch_lanes
    assign lane_eq[lane] = (rs1[8*lane +: 8] == rs2[8*lane +: 8]);
    if (lane < 3) begin : g_unsigned
      assign lane_lt[lane] = (rs1[8*lane +: 8] < rs2[8*lane +: 8]);
    end
  end
  // Flip the sign bit for signed inequalities before the top eight-bit
  // comparison. Register-only funct3[1] chooses the ordering, avoiding
  // another late signed/unsigned predicate mux after the merge.
  assign ordered_top_rs1 = {rs1[31] ^ !in.ctrl.branch_op[1], rs1[30:24]};
  assign ordered_top_rs2 = {rs2[31] ^ !in.ctrl.branch_op[1], rs2[30:24]};
  assign lane_lt[3] = ordered_top_rs1 < ordered_top_rs2;
  for (genvar pair = 0; pair < 2; pair++) begin : g_branch_pairs
    assign pair_eq[pair] = lane_eq[2*pair+1] && lane_eq[2*pair];
    assign pair_lt[pair] = lane_lt[2*pair+1] ||
                           (lane_eq[2*pair+1] && lane_lt[2*pair]);
  end
  assign equal_operands = pair_eq[1] && pair_eq[0];
  assign ordered_less = pair_lt[1] || (pair_eq[1] && pair_lt[0]);
  assign branch_base = in.ctrl.branch_op[2] ? ordered_less : equal_operands;
  assign branch_polarity = in.ctrl.branch_op[0];
  // This XOR uses only held registers and is ready before forwarded data.
  assign recovery_polarity = in.ctrl.branch_op[0] ^ in.predicted_taken;
  assign branch_cond = branch_base ^ branch_polarity;
  assign branch_mismatch = branch_base ^ recovery_polarity;

  always_comb begin
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

  assign advance_ex = !reset && !stall && !execute_hold && !squash;
  assign conditional_repair_target = in.predicted_taken ? (in.pc + 32'd4) : branch_target;
  assign recovery_valid = advance_ex && in.valid && !in.ctrl.is_illegal &&
                    ((in.ctrl.is_branch && branch_target[1:0] == 2'b00 && branch_mismatch) ||
                     (in.ctrl.is_jump && jump_target[1:0] == 2'b00 &&
                      (in.ctrl.is_jalr || !in.predicted_taken)));
  assign recovery_target = in.ctrl.is_jump ? jump_target : conditional_repair_target;

  // Recovery travels with the older transfer into MEM. Only MEM
  // advancement consumes it; younger dependencies/holds cannot delay it.
  always_ff @(posedge clock) begin
    if (reset) begin
      recovery_valid_q <= 1'b0;
      recovery_target_q <= '0;
    end else if (!stall) begin
      recovery_valid_q <= recovery_valid;
      recovery_target_q <= recovery_target;
    end
  end
  assign redirect = !reset && !stall && recovery_valid_q;
  assign redirect_target = recovery_target_q;

  // Consume this event on MEM advancement, one clock after comparison.
  // Dmem freezes retain it with EX/MEM; bubbles/divider waits invalidate it.
  predictor_train_t train_q;
  always_ff @(posedge clock) begin
    if (reset) train_q <= '0;
    else if (!stall) begin
      train_q.index <= in.pc[5:2] ^ in.pc[10:7];
      train_q.agree <= (branch_cond == (in.instr[14] ? in.instr[31] : in.instr[12]));
      train_q.valid <= !squash && !execute_hold && in.valid && !in.ctrl.is_illegal &&
                       in.ctrl.is_branch && (branch_target[1:0] == 2'b00);
    end
  end
  assign train = train_q;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t normal_payload;

  always_comb begin
    normal_payload = '0;
    normal_payload.pc            = in.pc;
    normal_payload.alu_result    = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
    // Dedicated byte-address lane bypasses the generic ALU operand/result muxes.
    normal_payload.effective_addr = rs1 + in.imm;
    normal_payload.fwd_ready     = ctrl_with_trap.reg_write && !in.ctrl.mem_to_reg &&
                                  !(in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                                    in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU ||
                                    in.ctrl.alu_op == ALU_SLL || in.ctrl.alu_op == ALU_SRL ||
                                    in.ctrl.alu_op == ALU_SRA);
    normal_payload.write_data    = rs2;
    normal_payload.rd            = in.rd;
    normal_payload.rs1_addr      = in.rs1_addr;
    normal_payload.rs2_addr      = in.rs2_addr;
    normal_payload.rs1_val       = rs1;
    normal_payload.rs2_val       = rs2;
    normal_payload.pc_next       = misalign_fault   ? (in.pc + 32'd4)
                                 : in.ctrl.is_jump ? jump_target
                                 : branch_taken    ? branch_target : (in.pc + 32'd4);
    normal_payload.branch_taken  = branch_taken;
    normal_payload.branch_target = branch_target;
    normal_payload.ctrl          = ctrl_with_trap;
    normal_payload.instr         = in.instr;
    normal_payload.valid         = in.valid;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!stall) begin
`ifndef RISCV_FORMAL_ALTOPS
      if (div_active_q && div_result_valid && div_transfer) begin
        reg_q <= div_metadata_q;
        reg_q.alu_result <= div_result;
      end else if (div_instruction || div_active_q) begin
        // Older MEM/WB instructions drain normally, exactly once. Every
        // waiting cycle replaces EX/MEM with a side-effect-free bubble.
        reg_q <= '0;
      end else
`endif
      begin
        reg_q <= normal_payload;
      end
      // Squash changes only side-effect controls. Ordinary wide payload
      // and result registers retain the same advancement rules above.
      if (squash) begin
        reg_q.valid <= 1'b0;
        reg_q.ctrl <= '0;
        reg_q.fwd_ready <= 1'b0;
      end
    end
  end

  assign out = reg_q;

`ifndef SYNTHESIS
  always @(posedge clock) begin
    if (recovery_valid) assert (recovery_target == normal_payload.pc_next);
    if (redirect) assert (redirect_target == reg_q.pc_next && reg_q.valid);
  end
`endif

endmodule
