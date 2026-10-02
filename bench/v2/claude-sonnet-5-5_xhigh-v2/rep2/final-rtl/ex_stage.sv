// rtl/ex_stage.sv
//
// Execute stage. Starts at the O/X operand flops (operands are already
// forwarded and the ALU operand select is folded in by of_stage): runs the
// ALU, resolves branches, computes the redirect target. Owns the EX/MEM
// pipeline register. Exports its combinational result (x_result) and the
// post-trap reg_write so of_stage can forward it into the next
// instruction's operand flops.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  ox_t      in,
  output ex_mem_t  out,
  // Forward-out to OF (dist-1): result and post-trap reg_write.
  output logic [31:0]        x_result,
  output logic               x_reg_write,
  // Registered mispredict redirect (redir_q / redir_tgt_*_q).
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               ex_busy,       // M op in EX, result not ready yet
  // BTB training (direct branch / JAL advancing out of EX)
  output logic               tr_en,
  output logic [19:2]        tr_pc,
  output logic               tr_taken,
  output logic               tr_is_jal,
  output logic               tr_is_ret,
  output logic [17:0]        tr_target,
  output logic               tr_hit,
  output logic [1:0]         tr_ctr,
  // Return-address stack update (call / return advancing out of EX)
  output logic               ras_push,
  output logic               ras_pop,
  output logic [19:2]        ras_push_addr
);

  // The instruction in EX is a wrong-path leftover while the registered
  // redirect is pending: it must not touch muldiv, EX/MEM or the BTB.
  logic ex_valid;
  assign ex_valid = in.valid && !redirect;

  // Operands come straight from the O/X flops (already forwarded).
  logic [31:0] rs1;
  logic [31:0] rs2;
  assign rs1 = in.rs1_v;
  assign rs2 = in.rs2_v;

  logic [31:0] alu_result;
  alu #(.HAS_MULDIV(0)) u_alu (
    .op  (in.ctrl.alu_op),
    .a   (in.opa),
    .b   (in.opb),
    .out (alu_result)
  );

  // ── Multi-cycle M-extension unit ──────────────────────────────────────
  // MUL/DIV/REM run in muldiv.sv. While it is busy the front of the
  // pipeline holds (hazard_unit, via ex_busy) and EX/MEM takes bubbles; on
  // the done cycle its result replaces the ALU result. Under
  // RISCV_FORMAL_ALTOPS is_muldiv is forced off so the ALU's algebraic
  // stand-ins are what the formal view sees.
  logic        is_muldiv;
  // done is implied by !ex_busy (EX/MEM only consumes the M result then).
  /* verilator lint_off UNUSEDSIGNAL */
  logic        md_done;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] md_result;
  // Latched operands are not needed: O/X holds rs1_v / rs2_v stable for the
  // whole time the M op sits in EX.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] md_a;
  logic [31:0] md_b;
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef RISCV_FORMAL_ALTOPS
  assign is_muldiv = 1'b0;
`else
  assign is_muldiv = in.is_md;   // pre-decoded in OF
`endif

  muldiv u_muldiv (
    .clock   (clock),
    .reset   (reset),
    .advance (!stall),
    .req     (is_muldiv && ex_valid),
    .op      (in.ctrl.alu_op),
    .a       (rs1),
    .b       (rs2),
    .busy    (ex_busy),
    .done    (md_done),
    .result  (md_result),
    .a_lat   (md_a),
    .b_lat   (md_b)
  );

  // EX result: M-op result, or the ALU result (JAL/JALR get their PC+4
  // return address through the ALU: of_stage sets opa = pc, opb = 4).
  // Feeds EX/MEM.alu_result and the dist-1 forward into OF's operand flops.
  assign x_result = is_muldiv ? md_result : alu_result;

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
    // pc + imm is precomputed in OF (in.btgt).
    branch_target = in.btgt;
    // JALR clears bit 0 (RV spec); JAL uses imm directly. jalr_sum is also
    // the load/store effective address (EX/MEM mem_addr).
    jalr_sum    = rs1 + in.imm;
    jump_target = in.ctrl.is_jalr ? {jalr_sum[31:1], 1'b0}
                                  : in.btgt;
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

    // Only JAL/JALR write a register among the instructions that can trap
    // here (branches have reg_write=0), so the reg_write clear depends on
    // misalign_jump alone (jalr_sum[1] / btgt[1:0], both early) and stays
    // off the late branch compare.
    ctrl_with_trap = in.ctrl;
    if (misalign_fault) ctrl_with_trap.is_illegal = 1'b1;
    if (misalign_jump)  ctrl_with_trap.reg_write  = 1'b0;
  end

  // Dist-1 forward-out to OF: post-trap reg_write and the result.
  assign x_reg_write = ctrl_with_trap.reg_write;

  // ── Architectural next PC ─────────────────────────────────────────────
  // Reverts to pc+4 on a misalign trap so the pc_fwd checker (asserting
  // next retirement's pc_rdata == this pc_wdata) stays consistent with the
  // suppressed redirect.
  logic [31:0] pc4;
  logic [31:0] pc_next_w;
  assign pc4 = in.pc4;

  // Structured so the late branch compare only drives a final 2:1 select:
  // everything else (JAL/JALR target, trap gating via btgt[1:0] / jalr_sum)
  // is resolved in parallel with the compare. is_branch and is_jump are
  // mutually exclusive, so this equals
  //   misalign_fault ? pc4 : is_jump ? jump_target : branch_taken ? btgt : pc4.
  logic [31:0] pc_nt;      // next PC if no branch is taken (incl. jumps)
  logic [31:0] tgt_b;      // branch target, trap-gated back to pc+4
  always_comb begin
    pc_nt = !in.ctrl.is_jump                         ? pc4
          : (jump_target[1:0] != 2'b00)              ? pc4
                                                     : jump_target;
    tgt_b = (in.btgt[1:0] != 2'b00) ? pc4 : in.btgt;
  end
  assign pc_next_w = (in.ctrl.is_branch && branch_cond) ? tgt_b : pc_nt;

  // ── Prediction check (every instruction, not just branches) ───────────
  // predicted next PC = what fetch actually did after this instruction.
  // The pc+4 and pc+imm compares are precomputed in OF (in.mp_seq /
  // in.mp_btgt); only the JALR-target compare runs here, in parallel with
  // the branch compare. The late branch_taken only does a final 2:1 select.
  // A non-CTI (or an aliased/stale BTB hit) simply mispredicts when
  // pred_taken disagrees with pc+4.
  logic [31:0] pred_full;
  logic        mp_seq;     // mispredict if the real next PC is pc+4
  logic        mp_btgt;    // ... if it is pc+imm (branch taken / JAL)
  logic        mp_jalr;    // ... if it is the JALR target
  logic        mis_tgt;    // pc+imm misaligned -> trap, next PC reverts to pc+4
  logic        mis_jalr;
  logic        is_jal;
  logic        mp_tgt;
  logic        mp_jr;
  logic        mispredict;

  always_comb begin
    pred_full = in.pred_taken ? {12'b0, in.pred_npc, 2'b00} : pc4;
    mp_seq    = in.mp_seq;
    mp_btgt   = in.mp_btgt;
    mp_jalr  = ({jalr_sum[31:1], 1'b0} != pred_full);
    mis_tgt   = (branch_target[1:0] != 2'b00);
    mis_jalr  = jalr_sum[1];
    is_jal    = in.ctrl.is_jump && !in.ctrl.is_jalr;
    mp_tgt    = mis_tgt  ? mp_seq : mp_btgt;
    mp_jr     = mis_jalr ? mp_seq : mp_jalr;
    mispredict = ex_valid && (in.ctrl.is_jalr          ? mp_jr
                            : (is_jal || (in.ctrl.is_branch && branch_taken))
                                                       ? mp_tgt
                                                       : mp_seq);
  end

  // ── Registered mispredict redirect ────────────────────────────────────
  // Set only when the mispredicting instruction advances out of EX (the
  // check is re-evaluated every cycle while it is held by dmem_stall /
  // ex_busy). While redir_q is set the wrong-path instruction in EX is
  // dead (ex_valid), IF is NOP'd (hazard flush_if) and ID/EX is flushed.
  // redir_q is sticky while the EX/MEM register is held by a dmem stall
  // (possible only when a non-CTI aliased BTB hit is the mispredicting
  // instruction and is itself a mem op) so the held wrong-path instruction
  // in EX is still killed when it finally moves.
  //
  // The redirect target is registered as its two candidates plus the branch
  // compare result, and selected after the flops: the late 32-bit compare
  // then ends at a single flop instead of fanning out into a 30-bit select.
  logic        redir_q;
  logic [31:0] redir_tgt_b_q;     // tgt_b  (branch taken)
  logic [31:0] redir_tgt_nt_q;    // pc_nt  (not taken / jump / trap)
  logic        redir_br_q;        // is_branch && branch_cond

  always_ff @(posedge clock) begin
    if (reset)         redir_q <= 1'b0;
    else if (redir_q)  redir_q <= stall;
    else               redir_q <= mispredict && !stall && !ex_busy;
  end

  always_ff @(posedge clock) begin
    if (!redir_q) begin
      redir_tgt_b_q  <= tgt_b;
      redir_tgt_nt_q <= pc_nt;
      redir_br_q     <= in.ctrl.is_branch && branch_cond;
    end
  end

  assign redirect        = redir_q;
  assign redirect_target = redir_br_q ? redir_tgt_b_q : redir_tgt_nt_q;

  // ── BTB training ──────────────────────────────────────────────────────
  // Direct branches and JAL only, once, when the instruction advances.
  // For a direct branch / JAL the trap condition reduces to "taken and the
  // pc+imm target is misaligned" (JAL's jump_target is btgt), so the JALR
  // adder stays out of this cone and branch_cond only enters at the end.
  // Returns (JALR x0, x1/x5) also train, as is_ret entries with a don't-care
  // target: allocation depends only on flop-fed decode fields, never on
  // jalr_sum or the branch compare.
  logic adv;           // the instruction in EX advances this cycle
  logic is_call;       // JAL/JALR linking to x1 / x5
  logic is_ret;        // JALR x0, 0(x1/x5)
  logic tr_en_early;
  assign adv     = ex_valid && !stall && !ex_busy;
  assign is_call = in.ctrl.is_jump && (in.rd == 5'd1 || in.rd == 5'd5);
  assign is_ret  = in.ctrl.is_jalr && (in.rd == 5'd0)
                   && (in.rs1_addr == 5'd1 || in.rs1_addr == 5'd5);
  assign tr_en_early = adv && (in.ctrl.is_branch || is_jal);
  assign tr_en     = (tr_en_early && !(tr_taken && (in.btgt[1:0] != 2'b00)))
                     || (adv && is_ret);
  assign tr_pc     = in.pc[19:2];
  assign tr_taken  = branch_taken || in.ctrl.is_jump;
  assign tr_is_jal = in.ctrl.is_jump;
  assign tr_is_ret = is_ret;
  assign tr_target = branch_target[19:2];
  assign tr_hit    = in.pred_hit;
  assign tr_ctr    = in.pred_ctr;

  // ── Return-address stack update ───────────────────────────────────────
  // Architectural: only instructions that advance out of EX (correct path)
  // push / pop, so no speculative repair is ever needed.
  assign ras_push      = adv && is_call;
  assign ras_pop       = adv && is_ret;
  assign ras_push_addr = in.pc4[19:2];

  // ── EX/MEM register ───────────────────────────────────────────────────
  ex_mem_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (ex_busy || redir_q) begin
      // M op still working in EX: send a bubble down the pipe (no false
      // forwarding, no double retire). The real instruction enters EX/MEM
      // on the done cycle. Same bubble for the wrong-path instruction
      // killed by the registered redirect.
      reg_q <= '0;
    end else begin
      reg_q.pc            <= in.pc;
      // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
      // sum (which is the jump target). The MEM/WB register's read-data
      // mux only kicks in for LOADs, so we route PC+4 here.
      reg_q.alu_result    <= x_result;
      // Load/store effective address (rs1 + imm), kept off the ALU result
      // mux so the dmem BSRAM address register is fed by one adder only.
      reg_q.mem_addr      <= jalr_sum;
      // rs1_v / rs2_v are held stable by O/X for the whole time an M op sits
      // in EX, so no operand patch-up is needed on the done cycle.
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= rs1;
      reg_q.rs2_val       <= rs2;
      reg_q.pc_next       <= pc_next_w;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
