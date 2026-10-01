// rtl/ex_stage.sv
//
// Execute stage. Selects forwarded operands directly from the registered
// EX/MEM result banks, computes parallel result banks, and registers independent PC
// candidates with narrow control. Owns the EX/MEM pipeline register.
//
// Registered forwarding enables: bits 18:0 = EX/MEM ALU banks,
// bit 19 = EX/MEM jump link, bit 20 = MEM/WB, bit 21 = ID/EX.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  logic               mem_correction, // older MEM redirect kills this EX work
  output logic               divide_hold,   // hold IF and ID/EX while dividing
  input  id_ex_t   in,
  input  logic               fwd_select_hold,
  input  logic [21:0]        fwd_rs1_enable,
  input  logic [21:0]        fwd_rs2_enable,
  input  ex_mem_t            fwd_ex_mem,    // independent EX/MEM result banks
  input  logic [31:0]        fwd_mem_wb,    // selected MEM/WB register
  output ex_mem_t  out,
  output logic               next_reg_write,
  output logic               branch_train_valid,
  output logic [4:0]         branch_train_index,
  output logic               branch_train_taken
);

  // ── Fused operand selection ────────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [21:0] fwd_rs1_enable_q, fwd_rs2_enable_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      fwd_rs1_enable_q <= 22'h20_0000;
      fwd_rs2_enable_q <= 22'h20_0000;
    end else if (!fwd_select_hold) begin
      fwd_rs1_enable_q <= fwd_rs1_enable;
      fwd_rs2_enable_q <= fwd_rs2_enable;
    end
  end
  forward_operand u_fwd_rs1 (
    .enable (fwd_rs1_enable_q), .banks (fwd_ex_mem),
    .wb_value (fwd_mem_wb), .held_value (in.rs1_val), .value (rs1)
  );
  forward_operand u_fwd_rs2 (
    .enable (fwd_rs2_enable_q), .banks (fwd_ex_mem),
    .wb_value (fwd_mem_wb), .held_value (in.rs2_val), .value (rs2)
  );

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] effective_addr;
  assign effective_addr = rs1 + in.imm;
  logic mem_misaligned;
  assign mem_misaligned = (in.ctrl.mem_read || in.ctrl.mem_write) &&
      ((in.ctrl.mem_width == 2'd2 && effective_addr[1:0] != 2'b00) ||
       (in.ctrl.mem_width == 2'd1 && effective_addr[0] != 1'b0));
  // JALR clears bit 0. Its alignment check needs only sum bit 1, so
  // compute that carry locally instead of routing through the full
  // effective-address adder into the next forwarding selector.
  logic jalr_misaligned;
  assign jalr_misaligned = rs1[1] ^ in.imm[1] ^
                           (rs1[0] & in.imm[0]);
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alu_result;
  alu #(.COMB_DIV(1'b0), .COMB_MUL(1'b0)) u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );
`endif

  // Capture each product directly from the forwarded operands. Selecting
  // the instruction's result happens only after the EX/MEM boundary.
`ifndef RISCV_FORMAL_ALTOPS
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;
  logic        [63:0] mul_uu;
  logic signed [63:0] mul_su;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_ss = $signed({{32{rs1[31]}}, rs1}) *
                  $signed({{32{rs2[31]}}, rs2});
  assign mul_uu = {32'b0, rs1} * {32'b0, rs2};
  assign mul_su = $signed({{32{rs1[31]}}, rs1}) *
                  $signed({32'b0, rs2});
`endif

  // One restoring unsigned divide step per clock. The ID/EX register stays
  // fixed from launch through the last step; only the forwarded source
  // values need capturing because their producers drain during the divide.
  // Formal ALTOPS retains the combinational substitute from alu.sv.
  logic [31:0] ex_rs1;
  logic [31:0] ex_rs2;
`ifdef RISCV_FORMAL_ALTOPS
  assign divide_hold = 1'b0;
  assign ex_rs1 = rs1;
  assign ex_rs2 = rs2;
`else
  logic        div_instruction;
  logic        div_launch;
  logic        div_busy_q;
  logic        div_ready_q;
  logic [5:0]  div_count_q;
  logic [31:0] div_quotient_q;
  logic [31:0] div_divisor_q;
  logic [31:0] div_remainder_q;
  logic [31:0] div_orig_a_q;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;
  logic [31:0] div_result_q;
  logic        div_zero_q;
  logic        div_rem_q;
  logic        div_neg_quot_q;
  logic        div_neg_rem_q;
  logic [32:0] div_trial;
  logic [31:0] div_difference;
  logic        div_subtract;
  logic [31:0] div_quotient_next;
  logic [31:0] div_remainder_next;
  logic [31:0] div_final_result;

  assign div_instruction = in.valid &&
      (in.ctrl.alu_op == ALU_DIV  || in.ctrl.alu_op == ALU_DIVU ||
       in.ctrl.alu_op == ALU_REM  || in.ctrl.alu_op == ALU_REMU);
  // An outstanding dmem operation owns EX/MEM until its handshake. It
  // takes priority over starting a divide and cannot be overwritten.
  assign div_launch = div_instruction && !div_busy_q && !div_ready_q &&
                      !stall && !mem_correction;
  assign divide_hold = !mem_correction && (div_launch || div_busy_q);

  assign div_trial = {div_remainder_q, div_quotient_q[31]};
  assign div_subtract = div_trial >= {1'b0, div_divisor_q};
  assign div_difference = div_trial[31:0] - div_divisor_q;
  assign div_remainder_next = div_subtract
      ? div_difference
      : div_trial[31:0];
  assign div_quotient_next = {div_quotient_q[30:0], div_subtract};

  always_comb begin
    if (div_zero_q)
      div_final_result = div_rem_q ? div_orig_a_q : 32'hffff_ffff;
    else if (div_rem_q)
      div_final_result = div_neg_rem_q ? -div_remainder_next : div_remainder_next;
    else
      div_final_result = div_neg_quot_q ? -div_quotient_next : div_quotient_next;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_busy_q      <= 1'b0;
      div_ready_q     <= 1'b0;
      div_count_q     <= '0;
      div_quotient_q  <= '0;
      div_divisor_q   <= '0;
      div_remainder_q <= '0;
      div_orig_a_q    <= '0;
      div_rs1_q       <= '0;
      div_rs2_q       <= '0;
      div_result_q    <= '0;
      div_zero_q      <= 1'b0;
      div_rem_q       <= 1'b0;
      div_neg_quot_q  <= 1'b0;
      div_neg_rem_q   <= 1'b0;
    end else if (mem_correction) begin
      // This EX instruction lies on the older control instruction's wrong path.
      div_busy_q  <= 1'b0;
      div_ready_q <= 1'b0;
    end else if (div_launch) begin
      div_busy_q      <= 1'b1;
      div_ready_q     <= 1'b0;
      div_count_q     <= '0;
      div_quotient_q  <= (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM)
                           && rs1[31] ? -rs1 : rs1;
      div_divisor_q   <= (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM)
                           && rs2[31] ? -rs2 : rs2;
      div_remainder_q <= '0;
      div_orig_a_q    <= rs1;
      div_rs1_q       <= rs1;
      div_rs2_q       <= rs2;
      div_zero_q      <= (rs2 == 32'b0);
      div_rem_q       <= (in.ctrl.alu_op == ALU_REM || in.ctrl.alu_op == ALU_REMU);
      div_neg_quot_q  <= (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM)
                         && (rs1[31] ^ rs2[31]);
      div_neg_rem_q   <= (in.ctrl.alu_op == ALU_DIV || in.ctrl.alu_op == ALU_REM)
                         && rs1[31];
    end else if (div_busy_q) begin
      div_quotient_q  <= div_quotient_next;
      div_remainder_q <= div_remainder_next;
      div_count_q     <= div_count_q + 6'd1;
      if (div_count_q == 6'd31) begin
        div_busy_q   <= 1'b0;
        div_ready_q  <= 1'b1;
        div_result_q <= div_final_result;
      end
    end else if (div_ready_q) begin
      div_ready_q <= 1'b0;
    end
  end

  assign ex_rs1 = div_ready_q ? div_rs1_q : rs1;
  assign ex_rs2 = div_ready_q ? div_rs2_q : rs2;
`endif

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] jalr_target;

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
    // This sum is independent of the general arithmetic result path.
    // JALR clears bit zero before the target is registered.
    jalr_target = {effective_addr[31:1], 1'b0};
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
                      && (in.pc_direct[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump &&
                      (in.ctrl.is_jalr ? jalr_misaligned
                                       : in.pc_direct[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end
  // Forwarding needs only the jump's alignment check. Branch alignment
  // can affect the retiring trap bit but branches never write a register;
  // keeping their 32-bit condition comparator off this enable shortens
  // the EX/MEM result -> branch -> forwarding-select path.
  assign next_reg_write = in.ctrl.reg_write &&
                          !(in.ctrl.is_jump &&
                            (in.ctrl.is_jalr ? jalr_misaligned :
                                                   (in.pc_direct[1:0] != 2'b00)));

  // A direct target is the same sum IF used for prediction, so only its
  // direction bit needs checking here. JALR has no IF target prediction.
  logic actual_taken;
  assign actual_taken = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  logic correction_needed;
  // IF predicts every aligned direct JAL taken and every misaligned direct
  // target not taken. Thus only a conditional branch can disagree with its
  // direct prediction. A misaligned branch is also predicted not taken and
  // falls through after trapping, so it needs no correction. JALR has no
  // direct prediction and redirects whenever its target is aligned.
  assign correction_needed = in.valid && !divide_hold &&
      ((in.ctrl.is_branch && in.pc_direct[1:0] == 2'b00 &&
        (in.predicted_taken != branch_cond)) ||
       (in.ctrl.is_jalr && !misalign_jump));
  logic [1:0] pc_select;
  always_comb begin
    pc_select = 2'd0;
    if (actual_taken)
      pc_select = in.ctrl.is_jalr ? 2'd2 : 2'd1;
  end

  // Register the branch feedback beside the EX comparator. IF applies it
  // on the following edge, as before, without routing the comparator result
  // across the core to an IF-stage register in the same cycle.
  logic       train_valid_q;
  logic [4:0] train_index_q;
  logic       train_taken_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      train_valid_q <= 1'b0;
      train_index_q <= '0;
      train_taken_q <= 1'b0;
    end else begin
      train_valid_q <= in.valid && in.ctrl.is_branch && !stall &&
                       !divide_hold && !mem_correction;
      train_index_q <= in.pc[6:2];
      train_taken_q <= branch_taken;
    end
  end
  assign branch_train_valid = train_valid_q;
  assign branch_train_index = train_index_q;
  assign branch_train_taken = train_taken_q;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (mem_correction) begin
      // MEM's older redirect wins over the younger instruction in EX.
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
`ifndef RISCV_FORMAL_ALTOPS
    end else if (div_launch || div_busy_q) begin
      // Let older MEM instructions retire, then send invalid bubbles while
      // the held divide runs. No old EX/MEM payload is replayed.
      reg_q <= '0;
`endif
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.add_result    <= alu_a + alu_b;
      // AUIPC is the only operation that needs the PC on the arithmetic
      // input. Feed the other banks directly from rs1, avoiding that mux
      // on their register-input paths.
      reg_q.sub_result    <= rs1 - alu_b;
      reg_q.and_result    <= rs1 & alu_b;
      reg_q.or_result     <= rs1 | alu_b;
      reg_q.xor_result    <= rs1 ^ alu_b;
      reg_q.slt_result    <= $signed(rs1) < $signed(alu_b);
      reg_q.sltu_result   <= rs1 < alu_b;
      reg_q.sll_result    <= rs1 << alu_b[4:0];
      reg_q.srl_result    <= rs1 >> alu_b[4:0];
      reg_q.sra_result    <= $unsigned($signed(rs1) >>> alu_b[4:0]);
      reg_q.lui_result    <= in.imm;
      reg_q.link_result   <= in.pc_sequential;
      reg_q.forward_op    <= 19'b1 << in.ctrl.alu_op;
`ifdef RISCV_FORMAL_ALTOPS
      reg_q.alt_result    <= alu_result;
      reg_q.div_result    <= '0;
      reg_q.mul_result   <= '0;
      reg_q.mulh_result  <= '0;
      reg_q.mulhu_result <= '0;
      reg_q.mulhsu_result <= '0;
`else
      reg_q.alt_result   <= '0;
      reg_q.div_result   <= div_result_q;
`endif
      reg_q.effective_addr <= effective_addr;
      reg_q.mem_misaligned <= mem_misaligned;
      reg_q.write_data    <= ex_rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= ex_rs1;
      reg_q.rs2_val       <= ex_rs2;
      reg_q.pc_sequential <= in.pc_sequential;
      reg_q.pc_direct     <= in.pc_direct;
      reg_q.pc_jalr       <= jalr_target;
      reg_q.pc_select     <= pc_select;
      reg_q.correction_valid <= correction_needed;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
`ifndef RISCV_FORMAL_ALTOPS
    // These banks are ignored when EX/MEM holds a divide bubble or a
    // redirect. Write them independently so the divide opcode does not
    // gate the DSP result register path.
    if (!reset && !stall) begin
      reg_q.mul_result    <= mul_uu[31:0];
      reg_q.mulh_result   <= $unsigned(mul_ss[63:32]);
      reg_q.mulhu_result  <= mul_uu[63:32];
      reg_q.mulhsu_result <= $unsigned(mul_su[63:32]);
    end
`endif
  end

  assign out = reg_q;

endmodule
