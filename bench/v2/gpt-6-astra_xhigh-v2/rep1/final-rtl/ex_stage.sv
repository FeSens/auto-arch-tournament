// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU and multiply partial products, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Source enables are decided in decode and registered with this payload.
// Raw forwarding and complete ALU selection independently mask the original
// data sources, avoiding a forwarding mux followed by an ALU-source mux.
//
// Latency:        1 cycle normally; DIV/REM occupy EX for capture with
//                 two-bit prefix work, seven phases, and sign/transfer.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               next_reg_write,
  output logic               execute_busy,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               train_valid,
  output logic [5:0]         train_index,
  output logic               train_agree
);

  // Raw operands remain available even when the ALU selects PC/immediate.
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    rs1 = (in.rs1_val & {32{in.raw_rs1_mask[0]}})
        | (fwd_ex_mem & {32{in.raw_rs1_mask[1]}})
        | (fwd_mem_wb & {32{in.raw_rs1_mask[2]}});
    rs2 = (in.rs2_val & {32{in.raw_rs2_mask[0]}})
        | (fwd_ex_mem & {32{in.raw_rs2_mask[1]}})
        | (fwd_mem_wb & {32{in.raw_rs2_mask[2]}});
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = (in.rs1_val & {32{in.alu_a_sel[0]}})
          | (fwd_ex_mem & {32{in.alu_a_sel[1]}})
          | (fwd_mem_wb & {32{in.alu_a_sel[2]}})
          | (in.pc      & {32{in.alu_a_sel[3]}});
    alu_b = (in.rs2_val & {32{in.alu_b_sel[0]}})
          | (fwd_ex_mem & {32{in.alu_b_sel[1]}})
          | (fwd_mem_wb & {32{in.alu_b_sel[2]}})
          | (in.imm     & {32{in.alu_b_sel[3]}});
  end

  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (alu_a),
    .b   (alu_b),
    .out (alu_result)
  );

  logic [135:0] mul_partials;
`ifdef RISCV_FORMAL_ALTOPS
  // ALTOPS uses the original ALU formula, registered in alu_result.
  // Forwarding eligibility and the late-result bubble are unchanged.
  assign mul_partials = '0;
`else
  // Multiply selects register operands, so these are fully forwarded.
  // Sharing the ALU source muxes avoids another wide operand-selection path.
  // The original raw rs1/rs2 are still captured independently for RVFI.
  mul_partial u_mul_partial (
    .op(in.ctrl.alu_op), .a(alu_a), .b(alu_b), .partials(mul_partials)
  );
`endif

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

  logic actual_taken, advancing;
  // On an accepted decode edge this instruction becomes the younger
  // forwarding producer, including when a held division completes.
  assign next_reg_write = in.valid && ctrl_with_trap.reg_write;
  assign actual_taken = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  assign advancing = in.valid && !stall && !execute_busy && !reset;
  // Direct predictions have exact targets; only direction can be wrong.
  // JALR always arrives unpredicted. Faulting transfers stay sequential.
  assign redirect = advancing && (actual_taken != in.predicted_taken);
  assign redirect_target = actual_taken
                           ? (in.ctrl.is_jump ? jump_target : branch_target)
                           : in.pc + 32'd4;
  assign train_valid = advancing && in.ctrl.is_branch
                       && !in.ctrl.is_illegal && !misalign_fault;
  assign train_index = in.pc[7:2];
  assign train_agree = (branch_taken == in.imm[31]);

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  ex_mem_t div_metadata_q;
  logic is_division, div_start, div_busy, div_done;
  logic [31:0] div_result;

  assign is_division = in.valid && (in.ctrl.alu_op == ALU_DIV
                      || in.ctrl.alu_op == ALU_DIVU
                      || in.ctrl.alu_op == ALU_REM
                      || in.ctrl.alu_op == ALU_REMU);
  assign div_start = is_division && !div_busy && !stall && !reset;
  assign execute_busy = (is_division || div_busy) && !div_done;

  div_unit u_div (
    .clock(clock), .reset(reset), .start(div_start),
    .op(in.ctrl.alu_op), .a(rs1), .b(rs2),
    .accept(!stall), .busy(div_busy), .done(div_done), .result(div_result)
  );

  // Capture the fully forwarded RVFI operands together with the request.
  // ID/EX remains held, but its original operand values can be stale once
  // the older forwarding sources drain away.
  always_ff @(posedge clock) begin
    if (reset) div_metadata_q <= '0;
    else if (div_start) begin
      div_metadata_q <= '0;
      div_metadata_q.pc <= in.pc;
      div_metadata_q.pc_next <= in.pc + 32'd4;
      div_metadata_q.rd <= in.rd;
      div_metadata_q.rs1_addr <= in.rs1_addr;
      div_metadata_q.rs2_addr <= in.rs2_addr;
      div_metadata_q.rs1_val <= rs1;
      div_metadata_q.rs2_val <= rs2;
      div_metadata_q.ctrl <= in.ctrl;
      div_metadata_q.instr <= in.instr;
      div_metadata_q.valid <= 1'b1;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_done) begin
      reg_q <= div_metadata_q;
      reg_q.alu_result <= div_result;
    end else if (execute_busy || !in.valid) begin
      // MEM advances the older instruction on this edge. Leave an inert
      // bubble behind; a divider hold must not replay its side effects.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.mul_partials  <= mul_partials;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
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
