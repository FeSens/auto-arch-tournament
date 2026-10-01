// rtl/ex_stage.sv
//
// Execute stage. Uses the ID-registered forwarding selects for its operand
// muxes, runs the ALU, resolves branches, and computes the redirect target.
// Owns the EX/MEM pipeline register.
//
// Forwarding select encoding (precomputed in ID and carried in id_ex_t):
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
  output logic               div_busy,      // hold fetch/decode until result is ready
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    case (in.fwd_rs1_sel)
      2'd1:    rs1 = fwd_ex_mem;
      2'd2:    rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (in.fwd_rs2_sel)
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

  // ── Iterative radix-2 divider ─────────────────────────────────────────
  logic        div_op;
  logic        div_is_signed;
  logic        div_is_rem;
  logic [31:0] exec_result;

  always_comb begin
    div_is_signed = (in.ctrl.alu_op == ALU_DIV) || (in.ctrl.alu_op == ALU_REM);
    div_is_rem    = (in.ctrl.alu_op == ALU_REM) || (in.ctrl.alu_op == ALU_REMU);
    div_op        = in.valid && ((in.ctrl.alu_op == ALU_DIV)  ||
                                 (in.ctrl.alu_op == ALU_DIVU) ||
                                 (in.ctrl.alu_op == ALU_REM)  ||
                                 (in.ctrl.alu_op == ALU_REMU));
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Formal substitutes M-extension operations in alu.sv too. Preserve that
  // single-cycle stand-in so the ordinary formal gate checks routing/stalls.
  always_comb begin
    div_busy    = 1'b0;
    exec_result = alu_result;
  end
`else
  logic [31:0] div_quotient_q;
  logic [31:0] div_divisor_q;
  logic [31:0] div_remainder_q;
  logic [5:0]  div_count_q;
  logic        div_active_q;
  logic        div_done_q;
  logic        div_quotient_neg_q;
  logic        div_remainder_neg_q;
  logic        div_result_is_rem_q;
  logic [31:0] div_result_q;
  logic [31:0] div_operand_a_q;
  logic [31:0] div_operand_b_q;
  logic [31:0] div_abs_a;
  logic [31:0] div_abs_b;
  logic [32:0] div_trial_remainder;
  logic [31:0] div_subtracted_remainder;
  logic        div_quotient_bit;
  logic [31:0] div_quotient_step;
  logic [31:0] div_remainder_step;
  logic [31:0] div_unsigned_result;

  always_comb begin
    div_abs_a = (div_is_signed && rs1[31]) ? (~rs1 + 32'd1) : rs1;
    div_abs_b = (div_is_signed && rs2[31]) ? (~rs2 + 32'd1) : rs2;

    div_trial_remainder = {div_remainder_q, div_quotient_q[31]};
    div_quotient_bit = (div_trial_remainder >= {1'b0, div_divisor_q});
    if (div_quotient_bit)
      div_subtracted_remainder = div_trial_remainder[31:0] - div_divisor_q;
    else
      div_subtracted_remainder = div_trial_remainder[31:0];
    div_quotient_step = {div_quotient_q[30:0], div_quotient_bit};
    div_remainder_step = div_subtracted_remainder;

    if (div_result_is_rem_q)
      div_unsigned_result = div_remainder_neg_q
                          ? (~div_remainder_step + 32'd1) : div_remainder_step;
    else
      div_unsigned_result = div_quotient_neg_q
                          ? (~div_quotient_step + 32'd1) : div_quotient_step;

    div_busy = div_op && !div_done_q;
    if (div_op)
      exec_result = div_done_q ? div_result_q : 32'b0;
    else
      exec_result = alu_result;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_quotient_q       <= 32'b0;
      div_divisor_q        <= 32'b0;
      div_remainder_q      <= 32'b0;
      div_count_q          <= 6'b0;
      div_active_q         <= 1'b0;
      div_done_q           <= 1'b0;
      div_quotient_neg_q   <= 1'b0;
      div_remainder_neg_q  <= 1'b0;
      div_result_is_rem_q  <= 1'b0;
      div_result_q         <= 32'b0;
      div_operand_a_q      <= 32'b0;
      div_operand_b_q      <= 32'b0;
    end else if (!stall) begin
      if (!div_op) begin
        div_active_q <= 1'b0;
        div_done_q   <= 1'b0;
        div_count_q  <= 6'b0;
      end else if (div_done_q) begin
        // The completed instruction enters EX/MEM on this edge.
        div_active_q <= 1'b0;
        div_done_q   <= 1'b0;
        div_count_q  <= 6'b0;
      end else if (!div_active_q) begin
        div_result_is_rem_q <= div_is_rem;
        div_quotient_neg_q  <= div_is_signed && (rs1[31] ^ rs2[31]);
        div_remainder_neg_q <= div_is_signed && rs1[31];
        div_operand_a_q     <= rs1;
        div_operand_b_q     <= rs2;
        div_count_q         <= 6'b0;
        if (rs2 == 32'b0) begin
          // RV32M defines quotient-by-zero as all ones and remainder as rs1.
          div_result_q <= div_is_rem ? rs1 : 32'hFFFFFFFF;
          div_active_q <= 1'b0;
          div_done_q   <= 1'b1;
        end else if (div_is_signed && rs1 == 32'h80000000 && rs2 == 32'hFFFFFFFF) begin
          // Signed overflow is defined, not trapped: INT_MIN / -1 = INT_MIN.
          div_result_q <= div_is_rem ? 32'b0 : 32'h80000000;
          div_active_q <= 1'b0;
          div_done_q   <= 1'b1;
        end else begin
          div_quotient_q  <= div_abs_a;
          div_divisor_q   <= div_abs_b;
          div_remainder_q <= 32'b0;
          div_active_q    <= 1'b1;
        end
      end else begin
        div_quotient_q  <= div_quotient_step;
        div_remainder_q <= div_remainder_step;
        if (div_count_q == 6'd31) begin
          div_result_q <= div_unsigned_result;
          div_active_q <= 1'b0;
          div_done_q   <= 1'b1;
        end else begin
          div_count_q <= div_count_q + 6'd1;
        end
      end
    end
  end
`endif

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    branch_taken  = in.branch_taken;
    branch_target = in.branch_target;
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
    misalign_branch = in.branch_misalign;
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  assign redirect        = in.ctrl.is_jump && !misalign_fault;
  assign redirect_target = jump_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_busy) begin
      // Drain older instructions while keeping the divide in ID/EX.
      // This bubble prevents the older EX/MEM instruction from being
      // replayed or retired repeatedly during the iterative operation.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : exec_result;
`ifdef RISCV_FORMAL_ALTOPS
      reg_q.write_data    <= rs2;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
`else
      reg_q.write_data    <= (div_op && div_done_q) ? div_operand_b_q : rs2;
      reg_q.rs1_val       <= (div_op && div_done_q) ? div_operand_a_q : rs1;
      reg_q.rs2_val       <= (div_op && div_done_q) ? div_operand_b_q : rs2;
`endif
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.branch_misalign <= misalign_branch;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
