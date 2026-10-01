// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM on
// selects registered in ID/EX), runs the ALU, the dedicated
// AGU adder (rs1 + imm -> EX/MEM.mem_addr, also the JALR target) and the
// branch compare, and produces the redirect controls. Owns the EX/MEM
// register.
//
// Forwarding (one rf bit, computed one cycle early by forward_unit):
//   ex  : EX/MEM.add_q | EX/MEM.oth_q (instruction immediately ahead)
//   rf  : ID/EX.rs?_val     (flip-flop regfile read + ID bypass of the
//                            MEM-stage result and the w_q write, merged
//                            in ID; x0 reads 0)
//         ID/EX.b_val       (ALU B: same for rs2, or the immediate)
// Every source is a fabric FF, so each operand is one 2:1 mux on
// registered selects. ALU A is always rs1 (AUIPC takes ID/EX.br_target
// through the early group). The
// SLL / SR shifters and the branch compare get their own (syn_keep) copies
// of the rs1 / rs2 muxes and of the shift amount, each on its own ID/EX
// select flop copy, so the adder / AGU operand nets stay short.
//
// Redirect: the branch condition `take` is computed once per consumer
// (syn_keep copies, one LUT after the compare chain) and is the LAST
// select of each: the IF PC mux (take_pc[3:0], one per PC byte) and the
// ID/EX kill bits (take_kill[1:0], one per 5 kill bits, already gated
// with the dmem stall). Every other input of those muxes (jump, JALR target,
// stall) is computed in parallel from registers / the AGU. EX/MEM.ctrl
// has no dependence on the compare chain.
//
// MUL* are not computed here: EX/MEM latches the post-forward rs1/rs2,
// their 33rd (sign-extension) bits and the one-hot MEM result selects,
// and mem_stage forms the product (mul_unit). The 1-bubble interlock in
// hazard_unit keeps a MUL's consumer out of EX while the MUL is in MEM,
// so EX/MEM.add_q / oth_q is never forwarded for a MUL or a LOAD (both
// halves are 0 for them, so MEM can OR them in without a select).
//
// Trap handling:
//   - BRANCH taken to a misaligned target: trap, no redirect. A BRANCH
//     never has reg_write / mem_read / mem_write set, so only is_illegal
//     is raised.
//   - JAL to a misaligned target: already a non-jump trap from ID.
//   - JALR to a misaligned target: trap, reg_write cleared, and redirect
//     to pc+4. The redirect kills the follower in ID, whose forwarding
//     select was computed against the JALR's (uncleared) reg_write.
//   - Misaligned LOAD/STORE: trap, reg_write / mem_read / mem_write
//     cleared here, so the dmem ports and MEM need no trap logic.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), mem_addr, and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // in.lu_arm is read by hazard_unit only.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0]        fwd_add,       // EX/MEM.add_q      (registered)
  input  logic [31:0]        fwd_oth,       // EX/MEM.oth_q      (registered)
  output ex_mem_t  out,
  // redirect controls (IF PC mux / ID-EX kill)
  output logic [3:0]         take_pc,       // taken branch (one per PC byte)
  output logic [1:0]         take_kill,     // taken branch && !stall (kill copies)
  output logic               jump,          // JALR / unpredicted JAL / p_bad in EX
  output logic               jlink,         // ... target = link (JALR / p_bad)
  output logic               p_ok_lo,       // predicted-taken branch: take -> link
  output logic               p_ok_hi,
  output logic               jalr_go,       // aligned JALR: PC <= agu_target
  output logic [31:0]        agu_target,    // {agu_sum[31:1], 1'b0}
  output logic [31:0]        br_target,     // ID/EX.br_target (BRANCH / JAL)
  output logic [31:0]        link,          // ID/EX.link (pc + 4)
  output logic               ex_busy        // divider iterating: hold IF/ID
);

  // ── Operand forwarding muxes (registered encoded selects) ──────────
  // Each operand bit is rf ? reg : EX/MEM, a 4-input function of fabric
  // FFs (one LUT4). Every mux copy has its own
  // ID/EX select flop copy (the main rs1 / rs2 / alu_b copies one per
  // 16-bit half), so no select flop drives more than ~16 loads. The EX/MEM
  // source is the OR of its two halves, folded into the same LUT4.
  logic [31:0] fwd_ex_mem;
  assign fwd_ex_mem = fwd_add | fwd_oth;

  logic [31:0] rs1     /* synthesis syn_keep=1 */;  // adder / logic / AGU / div / MUL
  logic [31:0] rs1_sll /* synthesis syn_keep=1 */;  // SLL shifter copy
  logic [31:0] rs1_sr  /* synthesis syn_keep=1 */;  // SRL / SRA shifter copy
  logic [31:0] rs1_cmp /* synthesis syn_keep=1 */;  // branch compare copy
  logic [31:0] rs2;
  logic [31:0] rs2_cmp /* synthesis syn_keep=1 */;  // branch compare copy
  logic [31:0] alu_b;
  logic [4:0]  shamt_l /* synthesis syn_keep=1 */;  // SLL copy of alu_b[4:0]
  logic [4:0]  shamt_r /* synthesis syn_keep=1 */;  // SR  copy of alu_b[4:0]

  always_comb begin
    rs1[15:0]    = in.sel_a_lo.rf  ? in.rs1_val[15:0]  : fwd_ex_mem[15:0];
    rs1[31:16]   = in.sel_a_hi.rf  ? in.rs1_val[31:16] : fwd_ex_mem[31:16];
    rs1_sll      = in.sel_a_sll.rf ? in.rs1_val        : fwd_ex_mem;
    rs1_sr       = in.sel_a_sr.rf  ? in.rs1_val        : fwd_ex_mem;
    rs1_cmp      = in.sel_a_cmp.rf ? in.rs1_val        : fwd_ex_mem;
    rs2[15:0]    = in.sel_r2_lo.rf ? in.rs2_val[15:0]  : fwd_ex_mem[15:0];
    rs2[31:16]   = in.sel_r2_hi.rf ? in.rs2_val[31:16] : fwd_ex_mem[31:16];
    rs2_cmp      = in.sel_r2_cmp.rf ? in.rs2_val       : fwd_ex_mem;
    alu_b[15:0]  = in.sel_b_lo.rf  ? in.b_val[15:0]    : fwd_ex_mem[15:0];
    alu_b[31:16] = in.sel_b_hi.rf  ? in.b_val[31:16]   : fwd_ex_mem[31:16];
    shamt_l      = in.sel_b_shl.rf ? in.b_val[4:0]     : fwd_ex_mem[4:0];
    shamt_r      = in.sel_b_shr.rf ? in.b_val[4:0]     : fwd_ex_mem[4:0];
  end

  // ── Iterative divider ─────────────────────────────────────────────────
  // A div starts on its first EX cycle, latching the post-forwarding
  // rs1/rs2, and holds ID/EX + PC (ex_busy) while EX/MEM takes bubbles.
  // On done, EX/MEM captures the result; the divider returns to idle only
  // when EX/MEM actually advances (!stall). ex_busy comes from registered
  // state only (ID/EX ctrl + the divider's done flop).
  logic        is_div;
  logic        div_idle;
  logic        div_done;
  logic [31:0] div_result;
  // Operands as latched at start, for RVFI rs1/rs2_rdata only (by the done
  // cycle the forwarding sources have retired and ID/EX.rs?_val is stale).
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;

  assign is_div  = in.ctrl.is_div;        // gated by valid / kill in ID/EX
  assign ex_busy = is_div && !div_done;

  divider u_div (
    .clock     (clock),
    .reset     (reset),
    .start     (is_div),
    .ack       (!stall),
    .is_signed (!in.instr[12]),   // funct3: 100 DIV, 101 DIVU,
    .is_rem    (in.instr[13]),    //         110 REM, 111 REMU
    .a         (rs1),
    .b         (rs2),
    .idle      (div_idle),
    .done      (div_done),
    .result    (div_result)
  );

  always_ff @(posedge clock) begin
    if (div_idle && is_div) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  // ── ALU ───────────────────────────────────────────────────────────────
  // Register-sourced result groups (JAL/JALR link, div result, AUIPC
  // pc + imm = br_target) are merged into one early term, settled in
  // parallel with the operand muxes.
  logic [31:0] early /* synthesis syn_keep=1 */;
  logic [31:0] alu_add_out;
  logic [31:0] alu_oth_out;

  assign early = ({32{in.alu_link}}  & in.link)
               | ({32{in.alu_div}}   & div_result)
               | ({32{in.alu_auipc}} & in.br_target);

  alu u_alu (
    .sel_add   (in.alu_add),
    .sel_slt   (in.alu_slt),
    .sel_sll   (in.alu_sll),
    .sel_sr    (in.alu_sr),
    .sel_logic (in.alu_logic),
    .lop       (in.alu_lop),
    .sub       (in.alu_sub),
    .cin       (in.alu_cin),
    .arith     (in.alu_arith),
    .uns       (in.alu_uns),
    .a         (rs1),
    .a_sll     (rs1_sll),
    .a_sr      (rs1_sr),
    .b         (alu_b),
    .shamt_l   (shamt_l),
    .shamt_r   (shamt_r),
    .early     (early),
    .add_out   (alu_add_out),
    .oth_out   (alu_oth_out)
  );

  // ── AGU: dmem address and JALR target ────────────────────────────────
  logic [31:0] agu_sum;
  assign agu_sum = rs1 + in.imm;

  // ── Branch resolve ────────────────────────────────────────────────────
  // Runs on its own operand copies (rs1_cmp / rs2_cmp). eq: XOR-reduce.
  // lt: one 33-bit compare chain, signed / unsigned via the registered
  // br_uns extend bit. cond = (use_lt ? lt : eq) ^ inv, with br_ok
  // (= is_branch && !br_misalign) a registered kill bit. Both outcomes of
  // lt are pre-formed from eq and registered bits:
  //   t_lt  = br_ok & (use_lt ? !inv : eq ^ inv)    (take if lt = 1)
  //   t_nlt = br_ok & (use_lt ?  inv : eq ^ inv)    (take if lt = 0)
  // so each take copy is one LUT after br_diff[32]: lt ? t_lt : t_nlt.
  // Four PC-mux copies (fanout 8 each) and two kill copies (5 bits each).
  logic        br_eq_v;
  logic        br_lt_v;
  logic        branch_cond;
  logic        branch_trap;
  logic        jalr_misalign;
  logic        t_lt        /* synthesis syn_keep=1 */;
  logic        t_nlt       /* synthesis syn_keep=1 */;
  logic        take_b0_w   /* synthesis syn_keep=1 */;
  logic        take_b1_w   /* synthesis syn_keep=1 */;
  logic        take_b2_w   /* synthesis syn_keep=1 */;
  logic        take_b3_w   /* synthesis syn_keep=1 */;
  logic        take_k0_w   /* synthesis syn_keep=1 */;
  logic        take_k1_w   /* synthesis syn_keep=1 */;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] br_diff;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    br_eq_v     = ~|(rs1_cmp ^ rs2_cmp);
    br_diff     = {rs1_cmp[31] & ~in.br_uns, rs1_cmp}
                - {rs2_cmp[31] & ~in.br_uns, rs2_cmp};
    br_lt_v     = br_diff[32];
    branch_cond = (in.br_use_lt ? br_lt_v : br_eq_v) ^ in.br_inv;
    // br_inv_t = br_inv ^ p_ok_br: a verified predicted-taken branch
    // redirects (to link) exactly when it is not taken.
    t_lt        = in.br_ok && (in.br_use_lt ? !in.br_inv_t : (br_eq_v ^ in.br_inv_t));
    t_nlt       = in.br_ok && (in.br_use_lt ?  in.br_inv_t : (br_eq_v ^ in.br_inv_t));
    take_b0_w   = br_lt_v ? t_lt : t_nlt;
    take_b1_w   = br_lt_v ? t_lt : t_nlt;
    take_b2_w   = br_lt_v ? t_lt : t_nlt;
    take_b3_w   = br_lt_v ? t_lt : t_nlt;
    take_k0_w   = !stall && (br_lt_v ? t_lt : t_nlt);
    take_k1_w   = !stall && (br_lt_v ? t_lt : t_nlt);
    branch_trap = in.ctrl.is_branch && branch_cond && in.br_misalign;
    // JALR clears bit 0 (RV spec); bit 1 set means a misaligned target.
    jalr_misalign = in.ctrl.is_jump && in.ctrl.is_jalr && agu_sum[1];
  end

  assign take_pc    = {take_b3_w, take_b2_w, take_b1_w, take_b0_w};
  assign take_kill  = {take_k1_w, take_k0_w};
  assign jump       = in.ctrl.is_jump;
  assign jlink      = in.jlink;
  assign p_ok_lo    = in.p_ok_lo;
  assign p_ok_hi    = in.p_ok_hi;
  assign jalr_go    = in.ctrl.is_jump && in.ctrl.is_jalr && !agu_sum[1];
  assign agu_target = {agu_sum[31:1], 1'b0};
  assign br_target  = in.br_target;
  assign link       = in.link;

  // Full redirect (RVFI pc_next only; pruned from the timed netlist).
  logic        redirect;
  logic [31:0] redirect_target;

  always_comb begin
    redirect        = in.arch_jump || (in.br_ok && branch_cond);
    redirect_target = !in.ctrl.is_jalr ? in.br_target
                    : jalr_misalign    ? in.link
                    :                    {agu_sum[31:1], 1'b0};
  end

  // ── Misaligned LOAD / STORE ───────────────────────────────────────────
  // RV32I requires word-aligned LW/SW and halfword-aligned LH/LHU/SH;
  // byte ops are always aligned (RISCV_FORMAL_ALIGNED_MEM contract).
  logic  mem_misalign;
  ctrl_t ctrl_with_trap;

  always_comb begin
    mem_misalign = (in.ctrl.mem_read || in.ctrl.mem_write) && (
                     (in.ctrl.mem_width == 2'd2 && agu_sum[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && agu_sum[0]   != 1'b0));

    ctrl_with_trap = in.ctrl;
    if (mem_misalign || jalr_misalign) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
      ctrl_with_trap.mem_read   = 1'b0;
      ctrl_with_trap.mem_write  = 1'b0;
    end
    // A BRANCH has no reg_write / mem_* to clear: only the trap flag
    // (RVFI-only) sees the compare chain.
    if (branch_trap) ctrl_with_trap.is_illegal = 1'b1;
  end

  // ── EX/MEM register ───────────────────────────────────────────────────
  logic ld;
  logic ld_byte;
  logic ld_word;

  assign ld      = in.ctrl.mem_to_reg;
  assign ld_byte = in.ctrl.mem_width == 2'd0;
  assign ld_word = in.ctrl.mem_width == 2'd2;

  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else begin
      reg_q.pc            <= in.pc;
      // Adder sum straight to its flop (gated by alu_add / alu_slt); the
      // other groups OR link / div / AUIPC (via `early`).
      reg_q.add_q         <= alu_add_out;
      reg_q.oth_q         <= alu_oth_out;
      reg_q.mem_addr      <= agu_sum;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.w_ok          <= ctrl_with_trap.reg_write && in.rd != 5'b0;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= in.ctrl.is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= in.ctrl.is_div ? div_rs2_q : rs2;
      // MUL operand extension bits (DSP inputs are all flops) and the
      // one-hot MEM result selects.
      reg_q.mul_ax        <= in.mul_a_sgn & rs1[31];
      reg_q.mul_bx        <= in.mul_b_sgn & rs2[31];
      reg_q.sel_mlo       <= in.mul_lo;
      reg_q.sel_mhi       <= in.mul_hi;
      // Load lane selects (byte / half / word, from agu_sum[1:0]); a
      // misaligned load clears reg_write, so its lanes are don't-care.
      reg_q.ld_b          <= {4{ld}} & (4'b0001 << agu_sum[1:0]);
      reg_q.ld_h0         <= ld && !ld_byte && !agu_sum[1];
      reg_q.ld_h2         <= ld && !ld_byte &&  agu_sum[1];
      reg_q.ld_hx         <= ld &&  ld_byte;
      reg_q.ld_w          <= ld &&  ld_word;
      reg_q.ld_wx         <= ld && !ld_word;
      reg_q.ld_s          <= {4{ld && in.ctrl.mem_sext && !ld_word}} &
                             (ld_byte ? (4'b0001 << agu_sum[1:0])
                                      : (agu_sum[1] ? 4'b1000 : 4'b0010));
      reg_q.pc_next       <= redirect ? redirect_target : in.link;
      // Predictor training: registered ID/EX bits only (the outcome is
      // recomputed in MEM from rs1_val / rs2_val).
      reg_q.tr_br         <= in.pk_v && in.tr_en && in.ctrl.is_branch;
      reg_q.tr_jal        <= in.pk_v && in.tr_en && in.tr_jal;
      reg_q.tr_bad        <= in.p_bad && !(in.tr_en &&
                                           (in.ctrl.is_branch || in.tr_jal));
      reg_q.br_use_lt     <= in.br_use_lt;
      reg_q.br_inv        <= in.br_inv;
      reg_q.br_uns        <= in.br_uns;
      reg_q.tr_off        <= in.imm[15:2];
      reg_q.pk_idx        <= in.pk_idx;
      reg_q.pk_tm         <= in.pk_tm;
      reg_q.pk_ctr        <= in.pk_ctr;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
      // Divider still iterating: the payload above is don't-care, turn it
      // into a bubble (no retire, no regfile write, no forward, no dmem).
      if (ex_busy) begin
        reg_q.valid          <= 1'b0;
        reg_q.ctrl.reg_write <= 1'b0;
        reg_q.w_ok           <= 1'b0;
        reg_q.ctrl.mem_read  <= 1'b0;
        reg_q.ctrl.mem_write <= 1'b0;
        reg_q.ctrl.is_mul    <= 1'b0;
        reg_q.sel_mlo        <= 1'b0;
        reg_q.sel_mhi        <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
