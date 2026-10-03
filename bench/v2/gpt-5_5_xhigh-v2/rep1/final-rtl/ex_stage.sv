// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
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
  input  logic [31:0]        direct_target,
  input  logic               direct_target_valid,
  input  logic [1:0]         fwd_rs1_sel,
  input  logic [1:0]         fwd_rs2_sel,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // WB-stage write-data mux output
  output ex_mem_t  out,
  output logic               long_stall,    // DIV/REM in progress in EX
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               direct_fold_req,
  output logic [31:0]        direct_fold_target
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

  // ── Iterative DIV/REM ─────────────────────────────────────────────────
  logic        is_mdiv_op;
  logic        mdiv_start;
  logic        mdiv_busy;
  logic        mdiv_done;
  logic [31:0] mdiv_result;
  logic        mdiv_pending_q;
  logic [31:0] mdiv_pending_result_q;
  logic [31:0] mdiv_rs1_q;
  logic [31:0] mdiv_rs2_q;
  logic        mdiv_accept;
  logic [31:0] mdiv_accepted_result;

  always_comb begin
    is_mdiv_op = in.valid && (
                  in.ctrl.alu_op == ALU_DIV  ||
                  in.ctrl.alu_op == ALU_DIVU ||
                  in.ctrl.alu_op == ALU_REM  ||
                  in.ctrl.alu_op == ALU_REMU
                );
    mdiv_accept = is_mdiv_op && (mdiv_done || mdiv_pending_q) && !stall;
    mdiv_start  = is_mdiv_op && !mdiv_busy && !mdiv_done
               && !mdiv_pending_q && !stall;
    long_stall  = is_mdiv_op && !mdiv_accept;
    mdiv_accepted_result = mdiv_pending_q ? mdiv_pending_result_q : mdiv_result;
  end

  mdiv_unit u_mdiv (
    .clock  (clock),
    .reset  (reset),
    .start  (mdiv_start),
    .op     (in.ctrl.alu_op),
    .a      (alu_a),
    .b      (alu_b),
    .busy   (mdiv_busy),
    .done   (mdiv_done),
    .result (mdiv_result)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      mdiv_pending_q        <= 1'b0;
      mdiv_pending_result_q <= 32'b0;
      mdiv_rs1_q            <= 32'b0;
      mdiv_rs2_q            <= 32'b0;
    end else begin
      if (mdiv_start) begin
        mdiv_rs1_q <= rs1;
        mdiv_rs2_q <= rs2;
      end

      if (mdiv_done && stall) begin
        mdiv_pending_q        <= 1'b1;
        mdiv_pending_result_q <= mdiv_result;
      end else if (mdiv_accept) begin
        mdiv_pending_q <= 1'b0;
      end
    end
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic        direct_control;
  logic        direct_taken;
  logic [31:0] direct_target_calc;
  logic [31:0] direct_target_resolved;
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
    direct_control = in.ctrl.is_branch || (in.ctrl.is_jump && !in.ctrl.is_jalr);
    direct_taken   = branch_taken || (in.ctrl.is_jump && !in.ctrl.is_jalr);
    direct_target_calc     = in.pc + in.imm;
    direct_target_resolved = (direct_target_valid && direct_control)
                           ? direct_target
                           : direct_target_calc;
    branch_target = direct_target_resolved;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : direct_target_resolved;
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

  assign redirect        = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  assign redirect_target = in.ctrl.is_jump ? jump_target : branch_target;
  assign direct_fold_req = in.valid
                         && direct_target_valid
                         && direct_taken
                         && !ctrl_with_trap.is_illegal;
  assign direct_fold_target = direct_target;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (mdiv_accept) begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= mdiv_accepted_result;
      reg_q.write_data    <= mdiv_rs2_q;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= mdiv_rs1_q;
      reg_q.rs2_val       <= mdiv_rs2_q;
      reg_q.pc_next       <= in.pc + 32'd4;
      reg_q.branch_taken  <= 1'b0;
      reg_q.branch_target <= 32'b0;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end else if (is_mdiv_op) begin
      // DIV/REM occupies EX until mdiv_done; inject bubbles downstream while
      // older instructions drain through MEM/WB.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= in.ctrl.is_jump ? (in.pc + 32'd4) : alu_result;
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
