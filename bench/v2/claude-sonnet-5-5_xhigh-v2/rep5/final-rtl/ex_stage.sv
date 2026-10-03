// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM), runs
// the ALU, resolves branches, computes the redirect target. Owns the
// EX/MEM pipeline register.
//
// Registered redirect: a branch / jump is still resolved here, but only the
// RESULT is registered (EX/MEM.redirect = actual_taken ^ pred_taken, and
// EX/MEM.redirect_target). IF / hazard unit act on that flop one cycle later,
// while the branch sits in MEM. In that cycle the op in EX is wrong-path and
// is squashed here: EX/MEM captures a bubble, the BHT is not trained and the
// MDU is not started. A redirecting op is never a memory op or an M-op, so
// stall (dmem) / ex_busy cannot coincide with it.
//
// Forwarding select (driven by forward_unit):
//   0 = ID/EX register value (no forward)
//   1 = EX/MEM aluResult (instruction immediately ahead in MEM)
// ID/EX.rs?_val are plain flops; the regfile read, the write-first bypass
// and the MEM/WB (two-ahead) bypass all happen in ID.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // The m1 forward-match bits of `in` are consumed by forward_unit at
  // top level, not here.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic               fwd_rs1_sel,
  input  logic               fwd_rs2_sel,
  input  logic               fwd_alu_a_sel, // forward into ALU operand A
  input  logic               fwd_alu_b_sel, // forward into ALU operand B
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  output ex_mem_t  out,
  output logic               ex_busy,       // M-op in EX, MDU result not ready
  // BHT training bus (to if_stage)
  output logic               bht_upd_en,
  output logic [6:0]         bht_upd_idx,
  output logic               bht_upd_taken
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  // 2:1 mux; the select comes from flops via one AND level (forward_unit).
  // The MEM/WB leg was already merged into in.rs?_val by ID.
  always_comb begin
    rs1 = fwd_rs1_sel ? fwd_ex_mem : in.rs1_val;
    rs2 = fwd_rs2_sel ? fwd_ex_mem : in.rs2_val;
  end

  // ── ALU operand selection ─────────────────────────────────────────────
  // The is_auipc / alu_src choice (pc / imm vs register) was made in ID
  // (in.alu_a_val / in.alu_b_val) and is folded into the forward select
  // (fwd_alu_*_sel is 0 for pc / imm operands), so each ALU operand is one
  // 2:1 mux off flops, parallel to the rs1/rs2 mux above.
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = fwd_alu_a_sel ? fwd_ex_mem : in.alu_a_val;
    alu_b = fwd_alu_b_sel ? fwd_ex_mem : in.alu_b_val;
  end

  // The redirect resolved by the op now in MEM (EX/MEM flop): the op in EX
  // is on the wrong path and is squashed.
  logic redirect_m;

  logic [31:0] add_res;
  logic        slt_res;
  logic [31:0] shift_res;
  alu_cand u_alu (
    .a         (alu_a),
    .b         (alu_b),
    .sub       (in.ctrl.alu_sub),
    .slt_u     (in.ctrl.slt_u),
    .sh_left   (in.ctrl.sh_left),
    .sh_arith  (in.ctrl.sh_arith),
    .add_res   (add_res),
    .slt_res   (slt_res),
    .shift_res (shift_res)
  );

  // ── Multi-cycle MDU (MUL/DIV/REM) ─────────────────────────────────────
  // The M-op sits in ID/EX until the MDU result register is valid. The
  // MDU latches the forwarded rs1/rs2 in the op's first EX cycle; ex_busy
  // depends only on ID/EX ctrl flops + MDU flops. While busy, EX/MEM
  // receives bubbles (see the register below); the hazard unit holds
  // IF and ID/EX.
  logic        is_mdu;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        mdu_res_valid;   // folded into ex_busy inside the MDU
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] mdu_result;
  logic [31:0] mdu_a;
  logic [31:0] mdu_b;

  assign is_mdu = in.ctrl.sel_mdu;

  // EX result: flat AND-OR over the one-hot select flops decoded in ID.
  // LUI uses in.alu_b_val directly (alu_src = 1 there, so no forward).
  logic [31:0] pc_plus4;
  logic [31:0] alu_result;
  assign pc_plus4 = in.pc + 32'd4;
  always_comb begin
    alu_result = ({32{in.ctrl.sel_add}}   & add_res)
               | ({32{in.ctrl.sel_and}}   & (alu_a & alu_b))
               | ({32{in.ctrl.sel_or}}    & (alu_a | alu_b))
               | ({32{in.ctrl.sel_xor}}   & (alu_a ^ alu_b))
               | ({32{in.ctrl.sel_slt}}   & {31'b0, slt_res})
               | ({32{in.ctrl.sel_shift}} & shift_res)
               | ({32{in.ctrl.sel_lui}}   & in.alu_b_val)
               | ({32{in.ctrl.sel_mdu}}   & mdu_result)
               | ({32{in.ctrl.sel_pc4}}   & pc_plus4);
  end

  mdu u_mdu (
    .clock     (clock),
    .reset     (reset),
    .stall     (stall),
    .start     (in.valid && is_mdu && !redirect_m),
    .op        (in.ctrl.alu_op),
    .a         (rs1),
    .b         (rs2),
    // Fast path: DSPs read the ID/EX operand flops in E0; an EX/MEM forward
    // into the op (fwd_hit) takes the slow path off the captured a_q / b_q.
    .a_id      (in.rs1_val),
    .b_id      (in.rs2_val),
    .fwd_hit   (fwd_rs1_sel | fwd_rs2_sel),
    .busy      (ex_busy),
    .res_valid (mdu_res_valid),
    .result    (mdu_result),
    .a_q       (mdu_a),
    .b_q       (mdu_b)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] jalr_sum;  // bit 0 dropped for the JALR target only

  // branch_op is funct3: [2] = relational (else BEQ/BNE), [1] = unsigned,
  // [0] = invert (BNE / BGE / BGEU). One equality + one 33-bit compare.
  logic cmp_eq;
  logic cmp_lt;
  always_comb begin
    cmp_eq = (rs1 == rs2);
    cmp_lt = $signed({!in.ctrl.branch_op[1] && rs1[31], rs1})
           < $signed({!in.ctrl.branch_op[1] && rs2[31], rs2});
    branch_cond   = (in.ctrl.branch_op[2] ? cmp_lt : cmp_eq) ^ in.ctrl.branch_op[0];
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // rs1 + imm: JALR target and the load / store address.
    jalr_sum    = rs1 + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses pc + imm (= branch_target).
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0} : branch_target;
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

  // Direction-only verify of the IF-stage prediction: redirect iff the
  // actual direction differs from the carried prediction. IF predicted from
  // the same word and PC, so a correct "taken" prediction already fetched
  // this instruction's own target and needs no target compare.
  //   pred=0, actual=1 -> jump / branch target   (incl. JALR, never predicted)
  //   pred=1, actual=0 -> fall-through pc+4      (wrong direction, illegal
  //                       BRANCH funct3, or misaligned target)
  //   pred=actual      -> no redirect
  logic        actual_taken;
  logic        redirect_d;
  logic [31:0] redirect_target_d;
  assign actual_taken      = (branch_taken || in.ctrl.is_jump) && !misalign_fault;
  // Killed on bubbles and while the op in MEM is already redirecting.
  assign redirect_d        = (actual_taken ^ in.pred_taken) && in.valid && !redirect_m;
  // No dependence on the compare result: flops + the jalr / branch adders.
  assign redirect_target_d = in.pred_taken      ? pc_plus4
                           : in.ctrl.is_jalr    ? {jalr_sum[31:1], 1'b0}
                                                : branch_target;

  // BHT training: one update per conditional branch leaving EX (a branch
  // held in EX by a dmem stall is counted once, on the cycle it moves on).
  // A squashed wrong-path branch does not train.
  assign bht_upd_en    = in.valid && in.ctrl.is_branch && !stall && !redirect_m;
  assign bht_upd_idx   = in.pc[8:2];
  assign bht_upd_taken = branch_taken;

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;
  assign redirect_m = reg_q.redirect;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      // M-ops take the MDU result register (a flop) instead of the ALU.
      reg_q.alu_result    <= alu_result;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // RVFI: an M-op reports the operands the MDU captured in its first
      // EX cycle; the live forwarded values are gone by the time it ends.
      reg_q.rs1_val       <= is_mdu ? mdu_a : rs1;
      reg_q.rs2_val       <= is_mdu ? mdu_b : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= misalign_fault     ? (in.pc + 32'd4)
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.redirect      <= redirect_d;
      reg_q.redirect_target <= redirect_target_d;
      reg_q.mem_addr      <= jalr_sum;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
      // M-op still computing: the op stays in EX, EX/MEM gets a bubble
      // (valid=0, ctrl=0 -> no reg_write / mem_read / mem_write). Same when
      // the op in MEM redirects: the op in EX is wrong-path (redirect_d is
      // already 0 for it).
      if (ex_busy || redirect_m) begin
        reg_q.ctrl        <= '0;
        reg_q.valid       <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
