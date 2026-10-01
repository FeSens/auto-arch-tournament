// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU and resolves branches. Integer results, memory
// addresses and frontend recovery are parallel registered output lanes.
//
// ID/EX captures complete one-hot selections in decode. EX only masks
// registered data; writer priority and PC/immediate overrides precede ID/EX.
//
// Latency:        1 cycle for fast operations; blocking MUL/DIV handshakes.
//                Recovery is applied from the registered EX/MEM owner.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.write_value (registered)
  output ex_mem_t  out,
  output logic               forward_write, // next near producer, trap-adjusted
  output logic               ex_wait,       // hold fetch and ID/EX, drain MEM/WB
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output predictor_update_t predictor_update
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = ({32{in.fwd_rs1_sel[0]}} & fwd_ex_mem) |
               ({32{in.fwd_rs1_sel[1]}} & fwd_mem_wb) |
               ({32{in.fwd_rs1_sel[2]}} & in.rs1_val);
  assign rs2 = ({32{in.fwd_rs2_sel[0]}} & fwd_ex_mem) |
               ({32{in.fwd_rs2_sel[1]}} & fwd_mem_wb) |
               ({32{in.fwd_rs2_sel[2]}} & in.rs2_val);

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  // Select each ALU input in parallel, independently of the raw source
  // network used by RVFI, stores, branches, JALR and effective addresses.
  assign alu_a = ({32{in.alu_a_sel[0]}} & fwd_ex_mem) |
                 ({32{in.alu_a_sel[1]}} & fwd_mem_wb) |
                 ({32{in.alu_a_sel[2]}} & in.rs1_val) |
                 ({32{in.alu_a_sel[3]}} & in.pc);
  assign alu_b = ({32{in.alu_b_sel[0]}} & fwd_ex_mem) |
                 ({32{in.alu_b_sel[1]}} & fwd_mem_wb) |
                 ({32{in.alu_b_sel[2]}} & in.rs2_val) |
                 ({32{in.alu_b_sel[3]}} & in.imm);

  logic [31:0] alu_result;
  logic is_div, div_owned_q, is_mul, mul_owned_q;
  logic div_req_valid, div_req_ready, div_result_valid, div_result_ready;
  logic mul_req_valid, mul_req_ready, mul_result_valid, mul_result_ready;
  logic [31:0] div_result;
  logic [31:0] mul_result;
  ex_mem_t blocking_instruction_q;

  assign is_div = in.valid && !redirect && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_DIVU ||
                   in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
  assign is_mul = in.valid && !redirect && !in.ctrl.is_illegal &&
                  (in.ctrl.alu_op == ALU_MUL || in.ctrl.alu_op == ALU_MULH ||
                   in.ctrl.alu_op == ALU_MULHU || in.ctrl.alu_op == ALU_MULHSU);
  // The initial request cycle also holds ID/EX. Only completion acceptance
  // releases it; dmem stall independently retains the older EX/MEM request.
  assign ex_wait = (is_div || is_mul || div_owned_q || mul_owned_q) &&
                  !((div_owned_q && div_result_valid) || (mul_owned_q && mul_result_valid));
  assign div_req_valid = is_div && !div_owned_q && !mul_owned_q && !stall && !reset;
  assign div_result_ready = div_owned_q && !stall && !reset;
  assign mul_req_valid = is_mul && !mul_owned_q && !div_owned_q && !stall && !reset;
  assign mul_result_ready = mul_owned_q && !stall && !reset;

  alu u_alu (
    .clock (clock),
    .reset (reset),
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result),
    .mul_req_valid (mul_req_valid),
    .mul_req_ready (mul_req_ready),
    .mul_result_valid (mul_result_valid),
    .mul_result_ready (mul_result_ready),
    .mul_result (mul_result),
    .div_req_valid (div_req_valid),
    .div_req_ready (div_req_ready),
    .div_result_valid (div_result_valid),
    .div_result_ready (div_result_ready),
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
  // instruction, resolve to PC+4 (recovering a stale prediction), and clear
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

  // ID/EX is held throughout M ownership, including the completion edge.
  // Its identity and control therefore also describe the saved M producer.
  // Consumer capture is disabled while EX waits or dmem holds.
  assign forward_write = in.valid && !redirect && ctrl_with_trap.reg_write;

  logic [31:0] sequential_pc, control_target;
  logic resolved_taken, mismatch_sequential, mismatch_target, advancing;
  logic computed_redirect;
  logic [31:0] computed_redirect_target;
  predictor_update_t computed_update;

  assign sequential_pc = in.pc + 32'd4;
  assign control_target = in.ctrl.is_jump ? jump_target : branch_target;
  assign resolved_taken = !in.ctrl.is_illegal && !misalign_fault &&
                          (branch_taken || in.ctrl.is_jump);
  // Compare both successors in parallel. Branch outcome selects a one-bit
  // mismatch, rather than feeding a wide PC mux into an equality comparator.
  assign mismatch_sequential = in.predicted_next_pc != sequential_pc;
  assign mismatch_target = in.predicted_next_pc != control_target;
  assign advancing = in.valid && !redirect && !reset && !stall && !ex_wait;
  assign computed_redirect = advancing &&
                             (resolved_taken ? mismatch_target : mismatch_sequential);
  assign computed_redirect_target = resolved_taken ? control_target : sequential_pc;

  always_comb begin
    computed_update.valid = advancing;
    computed_update.allocate = !in.ctrl.is_illegal &&
                                (in.ctrl.is_branch || in.ctrl.is_jump) &&
                                control_target[1:0] == 2'b00;
    computed_update.unconditional = in.ctrl.is_jump;
    computed_update.taken = branch_taken || in.ctrl.is_jump;
    computed_update.pc = in.pc;
    // Conditional branches train their target even when not taken.
    computed_update.target = control_target;
  end

  // Recovery belongs to the older EX/MEM token. Keep both validity and its
  // target until MEM can accept that token; table feedback is a one-shot
  // even when recovery remains pending through a stalled memory request.
  always_ff @(posedge clock) begin
    if (reset) begin
      redirect <= 1'b0;
      predictor_update.valid <= 1'b0;
    end else begin
      predictor_update <= computed_update;
      if (!stall) begin
        redirect <= computed_redirect;
        redirect_target <= computed_redirect_target;
      end
    end
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t fast_instruction;

  always_comb begin
    fast_instruction = '0;
    fast_instruction.pc            = in.pc;
    fast_instruction.alu_result    = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
    fast_instruction.effective_address = rs1 + in.imm;
    fast_instruction.write_data    = rs2;
    fast_instruction.rd            = in.rd;
    fast_instruction.rs1_addr      = in.rs1_addr;
    fast_instruction.rs2_addr      = in.rs2_addr;
    fast_instruction.rs1_val       = rs1;
    fast_instruction.rs2_val       = rs2;
    fast_instruction.pc_next       = resolved_taken ? control_target : sequential_pc;
    fast_instruction.branch_taken  = branch_taken;
    fast_instruction.branch_target = branch_target;
    fast_instruction.ctrl          = ctrl_with_trap;
    fast_instruction.instr         = in.instr;
    fast_instruction.valid         = in.valid;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_owned_q <= 1'b0;
      mul_owned_q <= 1'b0;
      blocking_instruction_q <= '0;
    end else if (div_req_valid && div_req_ready) begin
      div_owned_q <= 1'b1;
      // Capture the forwarded source values and all retirement metadata
      // once. Older forwarding sources can disappear while execution runs.
      blocking_instruction_q <= fast_instruction;
    end else if (mul_req_valid && mul_req_ready) begin
      mul_owned_q <= 1'b1;
      blocking_instruction_q <= fast_instruction;
    end else if (div_result_valid && div_result_ready) begin
      div_owned_q <= 1'b0;
    end else if (mul_result_valid && mul_result_ready) begin
      mul_owned_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (redirect) begin
      // MEM accepts the recovery owner at this edge. The extra younger EX
      // token must not replace it with a memory effect or an M producer.
      reg_q <= '0;
    end else if (div_owned_q && div_result_valid) begin
      reg_q <= blocking_instruction_q;
      reg_q.alu_result <= div_result;
    end else if (mul_owned_q && mul_result_valid) begin
      reg_q <= blocking_instruction_q;
      reg_q.alu_result <= mul_result;
    end else if (ex_wait) begin
      // The older MEM instruction advances once, then EX/MEM is empty.
      // Holding it here would repeatedly issue a store or retire it again.
      reg_q <= '0;
    end else begin
      reg_q <= fast_instruction;
    end
  end

  assign out = reg_q;

endmodule
