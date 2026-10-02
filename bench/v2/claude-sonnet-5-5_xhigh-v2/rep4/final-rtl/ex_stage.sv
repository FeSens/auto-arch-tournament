// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Operand forwarding is resolved in ID (see id_stage / forward_unit): the
// ID/EX register already holds the final, architecturally-forwarded
// rs1/rs2 values and the pre-muxed ALU B operand (alu_src ? imm : rs2), so
// EX consumes in.rs1_val / in.alu_b / in.rs2_val straight from flops. The
// result produced here (ex_res) is exported back to ID as the P1 bypass
// source for the instruction one behind.
//
// Mispredict / JALR recovery is a registered event: EX resolves the
// compare / jalr_sum / misalign check but captures only a 1-bit `redir` into
// EX/MEM. `redirect` (input) is that flop's output, one cycle later; while
// it is high the instruction in EX is a wrong-path one and is squashed to a
// bubble at the EX/MEM capture. The redirect target is EX/MEM.pc_next.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  output ex_mem_t  out,
  output logic               div_stall,     // divide in EX not finished yet
  input  logic               redirect,      // EX/MEM.redir: squash the EX instruction
  // ID-stage bypass source (value written to EX/MEM.alu_result)
  output logic [31:0]        ex_res,
  output logic               ex_res_en      // reg_write (rd != 0 folded) && !misalign_jump
);

  // ── Operands: straight from the ID/EX flops ────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  always_comb begin
    rs1 = in.rs1_val;
    rs2 = in.rs2_val;
  end

  // ── ALU ───────────────────────────────────────────────────────────────
  // A = rs1 (AUIPC does not use the ALU: its pc+imm comes from the PC-side
  // adder, see ex_res). B = in.alu_b, pre-muxed in ID. The multiplier reads
  // the raw rs1 / rs2 flops and the pre-decoded signedness bits.
  logic [31:0] alu_out;
  logic [31:0] p_lo;
  logic [31:0] p_hi;
  alu u_alu (
    .op    (in.ctrl.alu_op),
    .a     (rs1),
    .b     (in.alu_b),
    .mul_a (rs1),
    .mul_b (rs2),
    .sgn_a (in.ctrl.mul_sgn_a),
    .sgn_b (in.ctrl.mul_sgn_b),
    .out   (alu_out),
    .p_lo  (p_lo),
    .p_hi  (p_hi)
  );

  // MUL/MULH/MULHSU/MULHU: the product is merged only at the EX/MEM
  // alu_result flop (not in ex_res, the P1 bypass source), with one
  // pre-decoded one-hot AND-OR (mul_lo / mul_hi come from the decoder). The
  // decoder marks these ops late_res, so a consumer in ID takes the load-use
  // bubble and picks the product up through the P2 (MEM) bypass.
  logic [31:0] alu_result_d;

  // ── Dedicated load/store address adder ────────────────────────────────
  // Loads and stores are always rs1 + imm (is_auipc = 0), so the address
  // gets its own adder and flop: the dmem address pin is then fed by a
  // flop -> adder -> flop path with no ALU op mux, divider mux, jump mux or
  // multiplier in front of it.
  logic [31:0] maddr;
  always_comb begin
    maddr = rs1 + in.imm;
  end

  // ── Iterative divider (DIV / DIVU / REM / REMU) ───────────────────────
  // A divide sits in EX (ID/EX held, PC held, EX/MEM fed bubbles) from the
  // cycle it arrives until the divider reports `done`; in the done cycle
  // EX/MEM captures the registered quotient/remainder and the pipeline
  // moves on. The ID/EX operands are final and stay put while the register
  // is held (div_stall / dmem stall), so the divider simply reads them.
  //
  // Under RISCV_FORMAL_ALTOPS the divide ops use the alu.sv xor-of-sub
  // stand-ins instead, so div_op is tied to 0 and no divider is built.
  logic        div_op;
  logic        div_done;
  logic [31:0] div_result;
  logic [31:0] alu_result;

`ifdef RISCV_FORMAL_ALTOPS
  assign div_op     = 1'b0;
  assign div_done   = 1'b0;
  assign div_result = 32'b0;
`else
  logic div_is_signed;
  logic div_want_rem;
  /* verilator lint_off UNUSEDSIGNAL */
  logic div_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    // Gated with !redirect: a wrong-path divide squashed in EX must not start.
    div_op = in.valid && !redirect &&
                         (in.ctrl.alu_op == ALU_DIV  ||
                          in.ctrl.alu_op == ALU_DIVU ||
                          in.ctrl.alu_op == ALU_REM  ||
                          in.ctrl.alu_op == ALU_REMU);
    div_is_signed = (in.ctrl.alu_op == ALU_DIV) || (in.ctrl.alu_op == ALU_REM);
    div_want_rem  = (in.ctrl.alu_op == ALU_REM) || (in.ctrl.alu_op == ALU_REMU);
  end

  divider u_div (
    .clock     (clock),
    .reset     (reset),
    .hold      (stall),
    .start     (div_op),
    .is_signed (div_is_signed),
    .want_rem  (div_want_rem),
    .a         (rs1),
    .b         (rs2),
    .busy      (div_busy),
    .done      (div_done),
    .result    (div_result)
  );
`endif

  assign div_stall  = div_op && !div_done;
  assign alu_result = div_op ? div_result : alu_out;

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

  // ── Direction-only recovery (registered) ──────────────────────────────
  // IF already steered the next fetch to the B/J target for every
  // pred_taken instruction (JAL always, branches per the BHT), so EX only
  // checks the 1-bit direction. JAL counts as taken. JALR is never
  // predicted and always redirects. A misaligned target is never
  // predicted and traps here without redirecting.
  //   predicted taken, was not taken -> resume at pc+4
  //   predicted not-taken, was taken -> go to pc+imm (branch or JAL)
  // The corrected PC is already EX/MEM.pc_next (jump_target / branch_target /
  // pc+4 below); only the 1-bit request is captured here and acted on from
  // the EX/MEM flop one cycle later.
  logic actual_dir;
  logic redir_nxt;
  always_comb begin
    actual_dir = (in.ctrl.is_branch && branch_cond)
              || (in.ctrl.is_jump && !in.ctrl.is_jalr);
    redir_nxt  = (in.ctrl.is_jalr || (actual_dir ^ in.pred_taken))
                 && !misalign_fault;
  end

  // ── ID-stage bypass source ────────────────────────────────────────────
  // ex_res is what is written to EX/MEM.alu_result for every op except the
  // multiplier family (merged at the flop, see alu_result_d): for JAL/JALR
  // the return address (PC+4), for AUIPC pc+imm (the PC-side adder above,
  // in parallel with the ALU), else the ALU / divider result. The enable uses
  // misalign_jump only (not the late misalign_branch / branch_taken term):
  // branches never have reg_write = 1, so it is equivalent and keeps the
  // select off the compare cone. Valid-agnostic: bubbles have ctrl = '0 and
  // imem-stall NOPs have rd = 0.
  always_comb begin
    ex_res       = (in.ctrl.is_jump || in.ctrl.is_auipc)
                   ? (in.ctrl.is_jump ? (in.pc + 32'd4) : branch_target)
                   : alu_result;
    // rd != 0 is already folded into ctrl.reg_write (id_stage).
    ex_res_en    = in.ctrl.reg_write && !misalign_jump;
    alu_result_d = in.ctrl.mul_lo ? p_lo
                 : in.ctrl.mul_hi ? p_hi
                 :                  ex_res;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (div_stall || redirect) begin
      // Divide still running in EX: feed a bubble (valid=0, no reg/mem
      // writes) down the pipe. The divide itself retires later.
      // Recovery (redirect = EX/MEM.redir): the instruction in EX is on the
      // wrong path; squash it to a bubble (no dmem access, no retirement, it
      // cannot raise a new redir).
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so ex_res routes PC+4 here.
      reg_q.alu_result    <= alu_result_d;
      reg_q.maddr         <= maddr;
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
      reg_q.redir         <= redir_nxt;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
      reg_q.bwd           <= in.imm[31];
    end
  end

  assign out = reg_q;

endmodule
