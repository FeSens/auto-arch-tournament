// rtl/ex_stage.sv
//
// Execute stage. AND-ORs the ID-registered one-hot operand selects with
// the forwarding sources (the four unmerged EX/MEM result legs and
// MEM/WB.wb_data) and the ID-registered regfile / pc / constant values,
// runs the ALU and the AGU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register and the registered redirect
// (redirect_q / redirect_tgt_q), which squashes the wrong-path entry in
// EX one cycle after resolution.
//
// EX/MEM holds the ALU result as four unmuxed legs (sum / dif / sh / lg,
// lg also carries the muldiv result of M-ops) plus the producer's result
// class one-hot. A consumer's x select was split by that class in ID, so
// the leg merge folds into the consumer's operand AND-OR and no result
// mux sits inside the forwarding loop; mem_stage merges OR(class & leg)
// for write-back.
//
// Operand networks (each ~2 LUT levels from flops):
//   alu_a / alu_b : ALU and muldiv operands (pc / b_const legs folded in;
//                   LUI = 0 + imm, JAL/JALR link = pc + 4 via the adder)
//   rs1 / rs2     : raw source values — AGU base, store data, RVFI
//   cmp_a / cmp_b : branch compare only (own select flops, low fanout)
//
// The AGU (rs1 + imm) feeds the registered EX/MEM.mem_addr (sole source
// of the dmem address) and the JALR target. Misaligned loads/stores are
// detected here and trap with reg_write cleared before they reach
// EX/MEM, so ID's EX/MEM-rd compare already sees the cleared bit.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_mem_wb,    // MEM/WB.wb_data (registered)
  output ex_mem_t  out,
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               m_stall        // M-op in EX, muldiv not done
);

  ex_mem_t reg_q;

  // x-leg AND-OR: the EX/MEM leg selected by a class-split x select
  // (s = xsel_t as a plain vector {add, sub, sh, lg}).
  function automatic logic [31:0] xleg(input logic [3:0]  s,
                                       input logic [31:0] l_sum,
                                       input logic [31:0] l_dif,
                                       input logic [31:0] l_sh,
                                       input logic [31:0] l_lg);
    xleg = ({32{s[3]}} & l_sum) | ({32{s[2]}} & l_dif)
         | ({32{s[1]}} & l_sh)  | ({32{s[0]}} & l_lg);
  endfunction

  // ── One-hot operand networks ──────────────────────────────────────────
  logic [31:0] fw;   // MEM/WB.wb_data    (instruction two ahead)
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  logic [31:0] cmp_a;
  logic [31:0] cmp_b;

  always_comb begin
    fw = fwd_mem_wb;

    rs1   = xleg(in.s1_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.s1_w}} & fw) | ({32{in.s1_r}} & in.rs1_val);
    rs2   = xleg(in.s2_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.s2_w}} & fw) | ({32{in.s2_r}} & in.rs2_val);
    alu_a = xleg(in.a_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.a_w}}  & fw) | ({32{in.a_r}}  & in.rs1_val)
          | ({32{in.a_pc}} & in.pc);
    alu_b = xleg(in.b_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.b_w}}  & fw) | ({32{in.b_r}}  & in.rs2_val)
          | in.b_const;
    cmp_a = xleg(in.p1_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.p1_w}} & fw) | ({32{in.p1_r}} & in.rs1_val);
    cmp_b = xleg(in.p2_x, reg_q.sum, reg_q.dif, reg_q.sh, reg_q.lg)
          | ({32{in.p2_w}} & fw) | ({32{in.p2_r}} & in.rs2_val);
  end

  logic [31:0] alu_sum;
  logic [31:0] alu_dif;
  logic [31:0] alu_sh;
  logic [31:0] alu_lg;
  // Merged view: unit tests only (write-back merges in mem_stage).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] alu_merged;
  /* verilator lint_on UNUSEDSIGNAL */
  alu u_alu (
    .r_add  (in.r_add),
    .r_sub  (in.r_sub),
    .r_slt  (in.r_slt),
    .r_sltu (in.r_sltu),
    .r_xor  (in.r_xor),
    .r_or   (in.r_or),
    .r_and  (in.r_and),
    .r_sll  (in.r_sll),
    .r_shr  (in.r_shr),
    .r_sra  (in.r_sra),
    .a      (alu_a),
    .b      (alu_b),
    .sum    (alu_sum),
    .dif    (alu_dif),
    .sh     (alu_sh),
    .lg     (alu_lg),
    .out    (alu_merged)
  );

  // ── Registered redirect ───────────────────────────────────────────────
  // A mispredict / JALR resolved here is registered (redirect_q) and acts
  // one cycle later, when the branch has moved to EX/MEM: the PC takes
  // redirect_target, ID/EX is flushed (hazard_unit) and the instruction
  // then in EX -- the first wrong-path one -- is squashed here (bubble
  // into EX/MEM, no muldiv start, no redirect of its own). EX/MEM then
  // holds the branch (no memory op), so no dmem stall can delay the
  // squash. No EX-computed signal reaches the PC or the ID/EX enables.
  logic        redirect_q;
  logic [31:0] redirect_tgt_q;
  logic [31:0] redirect_pc4_q;
  logic        redirect_alt_q;

  // ── AGU ───────────────────────────────────────────────────────────────
  logic [31:0] agu;
  assign agu = rs1 + in.imm;

  // ── Multi-cycle M-extension unit ──────────────────────────────────────
  // An M-op starts on its first cycle in EX (the forwarded operands are
  // valid then; the unit latches them because the forwarding sources
  // drain away while it waits). Until muldiv reports done, m_stall holds
  // PC + ID/EX and EX/MEM captures a bubble. On the done cycle the op
  // advances with the registered muldiv result; ack (op leaves EX, not
  // dmem-stalled) returns the unit to idle so a back-to-back M-op starts
  // fresh. A wrong-path M-op squashed by redirect_q never starts (the
  // unit is idle then: the branch ahead of it already left EX).
  logic        is_mop;
  logic        m_idle;
  logic        m_done;
  logic [31:0] m_result;
  logic [31:0] m_a;
  logic [31:0] m_b;

  assign is_mop  = in.valid && in.ctrl.is_muldiv && !redirect_q;
  assign m_stall = is_mop && !m_done;

  // EX/MEM captures a bubble for a waiting M-op or a squashed entry.
  logic kill;
  assign kill = m_stall || redirect_q;

  muldiv u_muldiv (
    .clock  (clock),
    .reset  (reset),
    .start  (is_mop && m_idle),
    .ack    (m_done && !stall),
    .op     (in.ctrl.alu_op),
    .a      (alu_a),
    .b      (alu_b),
    .idle   (m_idle),
    .done   (m_done),
    .result (m_result),
    .a_lat  (m_a),
    .b_lat  (m_b)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  // The compare runs on its own operand copies (cmp_a = rs1, cmp_b = rs2
  // for branches). The branch type is an ID-registered one-hot
  // (c_eq/c_lt/c_ltu) plus an invert bit, so after the compare chains
  // only one LUT level forms the condition.
  logic        cmp_eq;
  logic        cmp_lt;
  logic        cmp_ltu;
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;
  logic [31:0] pc4;
  logic        win_out;   // real pc+imm left the IF target window

  always_comb begin
    cmp_eq      = (cmp_a == cmp_b);
    cmp_lt      = ($signed(cmp_a) < $signed(cmp_b));
    cmp_ltu     = (cmp_a < cmp_b);
    branch_cond = ((in.c_eq & cmp_eq) | (in.c_lt & cmp_lt) |
                   (in.c_ltu & cmp_ltu)) ^ in.c_inv;
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    pc4           = in.pc + 32'd4;
    // JALR clears bit 0 (RV spec); JAL uses pc + imm.
    jump_target = in.ctrl.is_jalr ? {agu[31:1], 1'b0} : branch_target;
    // IF predicts to {12'b0, (pc + imm)[19:0]}: that is the real target
    // only when its upper bits are zero.
    win_out     = (branch_target[31:20] != 12'b0);
  end

  // ── Misaligned target / access traps ──────────────────────────────────
  // riscv-formal demands rvfi_trap=1 when next_pc is misaligned (no C
  // extension: [1:0] != 0) or a load/store address is not aligned to its
  // width. The offending instruction traps with reg_write cleared and
  // pc_next = pc+4. A trapping JAL/JALR redirects to pc+4: that kills the
  // instruction behind it, whose ID-precomputed select may point at this
  // (now non-writing) rd, so it re-decodes against the cleared EX/MEM.
  logic misalign_branch;
  logic misalign_jump;
  logic misalign_fault;
  logic mem_mis;
  ctrl_t ctrl_with_trap;

  always_comb begin
    misalign_branch = branch_taken && (branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump &&
                      (in.ctrl.is_jalr ? agu[1] : (branch_target[1:0] != 2'b00));
    misalign_fault  = misalign_branch || misalign_jump;
    mem_mis         = (in.ctrl.mem_read || in.ctrl.mem_write) && (
                        (in.ctrl.mem_width == 2'd2 && agu[1:0] != 2'b00) ||
                        (in.ctrl.mem_width == 2'd1 && agu[0]   != 1'b0)
                        // 2'd0 (byte) is never misaligned.
                      );

    ctrl_with_trap = in.ctrl;
    if (misalign_fault || mem_mis) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
    // M-op still running, or wrong-path entry behind a registered
    // redirect: EX/MEM captures a bubble.
    if (kill) ctrl_with_trap = '0;
  end

  // Mispredict redirect. IF already steered the PC to pc+imm for a
  // predicted-taken branch / JAL (pt_ok: its truncated target was the
  // real one), so only a direction mismatch, an un-predicted or
  // out-of-window JAL and every JALR redirect. A misaligned taken branch
  // is suppressed (pc+4 is already behind it); a misaligned JAL/JALR
  // redirects to pc+4 (see above). IF never predicts a misaligned target.
  // The late branch_cond only picks between two precomputed fire terms
  // (Ft / Fn), and the fire is registered only when the branch leaves EX
  // (!stall). The target is cond-independent: a predicted-taken branch
  // whose target left the window may go either way, so its pc+4 is
  // registered too and picked after the edge by the registered outcome.
  logic tgt_seq;
  logic pt_ok;       // IF's prediction steered to the real target
  logic fire_ok;     // this entry may redirect: real, not squashed, leaving
  logic fire_u;      // unconditional: JALR, un-predicted JAL
  logic fire_t;      // if the branch is taken: predicted not-taken
  logic fire_n;      // if the branch is not taken: predicted taken
  logic fire_tt;     // Ft = fire_u | fire_t
  logic fire_nn;     // Fn = fire_u | fire_n
  logic redirect_fire;
  logic [31:0] redirect_target_d;

  always_comb begin
    pt_ok    = in.pred_taken && !win_out;
    tgt_seq  = in.ctrl.is_jalr ? agu[1]
                               : (branch_target[1] ||
                                  (in.ctrl.is_branch && pt_ok));
    fire_ok  = in.valid && !redirect_q && !stall;
    fire_u   = fire_ok && (in.ctrl.is_jalr ||
                           (in.ctrl.is_jump && !pt_ok));
    fire_t   = fire_ok && in.ctrl.is_branch && !pt_ok &&
               (branch_target[1:0] == 2'b00);
    fire_n   = fire_ok && in.ctrl.is_branch && in.pred_taken;
    fire_tt  = fire_u || fire_t;
    fire_nn  = fire_u || fire_n;
    redirect_fire = branch_cond ? fire_tt : fire_nn;
    redirect_target_d = tgt_seq         ? pc4
                      : in.ctrl.is_jalr ? {agu[31:1], 1'b0}
                                        : branch_target;
  end

  always_ff @(posedge clock) begin
    if (reset) redirect_q <= 1'b0;
    else       redirect_q <= redirect_fire;
    redirect_tgt_q <= redirect_target_d;
    redirect_pc4_q <= pc4;
    redirect_alt_q <= in.ctrl.is_branch && in.pred_taken && win_out;
  end

  // The firing branch sits in EX/MEM when redirect_q is high, so its
  // registered outcome picks pc+4 for a not-taken out-of-window one.
  assign redirect        = redirect_q;
  assign redirect_target = (redirect_alt_q && !reg_q.branch_taken)
                         ? redirect_pc4_q : redirect_tgt_q;

  // ── EX/MEM register ───────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      // Unmerged result legs, each straight from its unit. JAL/JALR link
      // (pc+4) comes out of the adder; M-ops take the registered muldiv
      // result on the lg leg.
      reg_q.sum           <= alu_sum;
      reg_q.dif           <= alu_dif;
      reg_q.sh            <= alu_sh;
      reg_q.lg            <= in.ctrl.is_muldiv ? m_result : alu_lg;
      reg_q.c             <= in.k;
      reg_q.mem_addr      <= agu;
      reg_q.mem_mis       <= mem_mis;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // RVFI-only: an M-op's forwarding sources may have drained by its
      // done cycle, so report the operands muldiv latched at start.
      reg_q.rs1_val       <= in.ctrl.is_muldiv ? m_a : rs1;
      reg_q.rs2_val       <= in.ctrl.is_muldiv ? m_b : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the pc+4 continuation.
      reg_q.pc_next       <= misalign_fault     ? pc4
                            : in.ctrl.is_jump   ? jump_target
                            : branch_taken      ? branch_target
                                                : pc4;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !kill;
      reg_q.pred_ctr      <= in.pred_ctr;
    end
  end

  assign out = reg_q;

endmodule
