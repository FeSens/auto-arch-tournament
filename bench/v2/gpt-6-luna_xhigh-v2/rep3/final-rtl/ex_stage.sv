// rtl/ex_stage.sv
//
// Execute stage. Consumes operands already selected and captured by decode,
// runs the ALU, resolves branches, computes the redirect target, and owns
// the EX/MEM pipeline register.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  output logic               busy,          // DIV/REM holds IF and ID until done
  input  id_ex_t   in,
  input  logic               squash,        // registered redirect kill sideband
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               fwd_valid,
  output logic [4:0]         fwd_rd,
  output logic [31:0]        fwd_data
);

  // Decode has already resolved dependencies into the ID/EX payload.
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── ALU operand selection ─────────────────────────────────────────────
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = in.ctrl.is_auipc ? in.pc  : rs1;
    alu_b = in.ctrl.alu_src  ? in.imm : rs2;
  end

  logic [31:0] alu_result;
  logic        div_start;
  logic        div_consume;
  logic        div_busy;
  logic        div_done;
  logic        div_instruction;
  logic        live_valid;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;
  logic        div_result_valid;

  // Keep the kill sideband off operands and ALU results. It only controls
  // instruction validity and architectural EX activity.
  assign live_valid = in.valid && !squash;

  assign div_instruction = live_valid &&
                           (in.ctrl.alu_op == ALU_DIV  ||
                            in.ctrl.alu_op == ALU_DIVU ||
                            in.ctrl.alu_op == ALU_REM  ||
                            in.ctrl.alu_op == ALU_REMU);
  assign div_result_valid = div_instruction && div_done;

  // Forwarding sources can change while EX is occupied. Snapshot the
  // architectural operands on the same edge that starts the divider so
  // the eventual RVFI payload reports the values actually divided.
  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Formal sees the same algebraic substitutes as the riscv-formal spec.
  // Avoid introducing 32 cycles of latency into the shallow ALTOPS BMC.
  assign div_start   = 1'b0;
  assign div_consume = 1'b0;
  assign busy        = 1'b0;
`else
  assign div_start   = div_instruction && !div_busy && !div_done;
  assign div_consume = div_instruction && div_done && !stall;
  assign busy        = div_instruction && !div_done;
`endif

  alu u_alu (
    .op          (in.ctrl.alu_op),
    .a           (alu_a),
    .b           (alu_b),
    .clock       (clock),
    .reset       (reset),
    .div_start   (div_start),
    .div_consume (div_consume),
    .div_busy    (div_busy),
    .div_done    (div_done),
    .out         (alu_result)
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
    if (squash) begin
      ctrl_with_trap.reg_write  = 1'b0;
      ctrl_with_trap.mem_read   = 1'b0;
      ctrl_with_trap.mem_write  = 1'b0;
      ctrl_with_trap.mem_to_reg = 1'b0;
    end
  end

  assign redirect        = !squash && (branch_taken || in.ctrl.is_jump) &&
                           !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_target;

  // Same-cycle bypass for the instruction currently in ID/EX. It is the
  // youngest possible producer when decode captures the following
  // instruction. Loads are excluded because their value is not available
  // until MEM; they use the dedicated ready-gated MEM bypass instead.
  assign fwd_valid = live_valid && ctrl_with_trap.reg_write &&
                     !in.ctrl.mem_to_reg && !busy;
  assign fwd_rd    = in.rd;
  assign fwd_data  = in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (busy) begin
      // A long divide occupies EX. Let the older EX/MEM instruction drain
      // once, then keep a bubble in EX/MEM so it cannot repeat a store or
      // retirement while the divider runs.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
      reg_q.write_data    <= div_result_valid ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= div_result_valid ? div_rs1_q : rs1;
      reg_q.rs2_val       <= div_result_valid ? div_rs2_q : rs2;
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
      reg_q.valid         <= live_valid;
    end
  end

  assign out = reg_q;

endmodule
