// rtl/ex_stage.sv
//
// Execute stage. Runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// There is no forwarding or operand-select logic here: id_stage.sv bypasses
// the producing instruction's result into the ID/EX operand registers
// (a_val / b_val / rs1_val / rs2_val), so every EX cone starts at a flop.
// ex_result (the value written to EX/MEM.alu_result) and jump_misal_ex are
// exported to ID for that bypass.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // imm / alu_src / is_auipc ... are consumed in ID (operand formation).
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  // The fetch pc register (if_id_w.pc). While a valid instruction sits in
  // EX this holds the address that was fetched after it (pc only advances
  // on the cycle the instruction is captured; stalls hold it; a redirect
  // rewrites it), so comparing it with the architectural next PC verifies
  // whatever the fetch-side BTB predicted.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]        fetch_pc,       // [1:0] always 0, not compared
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_mem_t  out,
  output logic               md_stall,      // MUL/DIV in EX, result not ready
  output logic [31:0]        ex_result,     // value written to EX/MEM.alu_result
                                            // (consumed by ID's operand bypass)
  output logic               jump_misal_ex  // JAL/JALR in EX traps on a
                                            // misaligned target (its reg_write
                                            // is cleared; ID must not bypass it)
);

  // ── EX/MEM register (declared early: reg_q.redir squashes EX) ──────────
  ex_mem_t reg_q;

  // The instruction in EX is a wrong-path instruction when the one ahead of
  // it (now in MEM) is applying a late redirect: it must not redirect, start
  // MUL/DIV, trap-forward or enter MEM (it becomes a bubble below).
  logic ex_valid;
  assign ex_valid = in.valid && !reg_q.redir;

  // ── ALU ───────────────────────────────────────────────────────────────
  // a_val = AUIPC ? pc : rs1, b_val = alu_src ? imm : rs2 (both already
  // forwarded, formed in ID). Branches / JAL / R-type have alu_src = 0, so
  // for them a_val / b_val are exactly rs1 / rs2; JALR has alu_src = 1, so
  // a_val + b_val is rs1 + imm.
  logic [31:0] alu_result;
  alu u_alu (
    .op  (in.ctrl.alu_op),
    .a   (in.a_val),
    .b   (in.b_val),
    .out (alu_result)
  );

  // ── Multi-cycle MUL/DIV/REM ───────────────────────────────────────────
  // The instruction is held in EX (EX/MEM gets bubbles) until the muldiv
  // unit raises `done`. Operands are a_val / b_val (MUL/DIV are R-type, so
  // these are exactly rs1/rs2). ID/EX holds during the stall, and the unit
  // latches them on the first EX cycle as well.
  // Under RISCV_FORMAL_ALTOPS the combinational stand-ins in alu.sv stay in
  // force and no stall ever occurs.
  logic        md_op;
  logic        md_done;
  logic [31:0] md_result;

`ifdef RISCV_FORMAL_ALTOPS
  assign md_op     = 1'b0;
  assign md_done   = 1'b0;
  assign md_result = 32'b0;
`else
  // The unit's latched operands are not needed any more: ID/EX holds the
  // final operands for the whole stall and carries the RVFI rs?_val itself.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] md_a;
  logic [31:0] md_b;
  /* verilator lint_on UNUSEDSIGNAL */
  logic md_consume;
  assign md_op      = ex_valid && (in.ctrl.alu_op >= ALU_MUL);
  assign md_consume = md_op && md_done && !stall;

  muldiv u_muldiv (
    .clock   (clock),
    .reset   (reset),
    .start   (md_op && !stall),
    .op      (in.ctrl.alu_op),
    .a       (in.a_val),
    .b       (in.b_val),
    .consume (md_consume),
    .done    (md_done),
    .result  (md_result),
    .a_lat   (md_a),
    .b_lat   (md_b)
  );
`endif

  assign md_stall = md_op && !md_done;

  // ── Branch resolve ────────────────────────────────────────────────────
  // The PC-relative target (pc+imm), its misalign flag and pc+4 are
  // precomputed in ID and arrive as registered fields (in.tgt,
  // in.tgt_misal, in.pc_plus4); only JALR's rs1+imm adder lives here.
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] jalr_target;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] jalr_sum;  // bit 0 deliberately dropped per RV JALR spec
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond = (in.a_val == in.b_val);
      BR_BNE:  branch_cond = (in.a_val != in.b_val);
      BR_BLT:  branch_cond = ($signed(in.a_val) <  $signed(in.b_val));
      BR_BGE:  branch_cond = ($signed(in.a_val) >= $signed(in.b_val));
      BR_BLTU: branch_cond = (in.a_val <  in.b_val);
      BR_BGEU: branch_cond = (in.a_val >= in.b_val);
      default: branch_cond = 1'b0;
    endcase
    branch_taken = in.ctrl.is_branch && branch_cond;
    // JALR clears bit 0 (RV spec); JAL / branches use the ID-computed tgt.
    jalr_sum    = in.a_val + in.b_val;
    jalr_target = {jalr_sum[31:1], 1'b0};
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  // A JALR target is {jalr_sum[31:1], 0}, so it is misaligned iff
  // jalr_sum[1]; branches / JAL use the precomputed tgt_misal.
  // jump_misal_ex is the early part of the fault (no branch compare): only
  // jumps write rd, so it is all ID's bypass gating needs.
  logic misalign_fault;
  ctrl_t ctrl_with_trap;

  assign jump_misal_ex = in.ctrl.is_jump
                      && (in.ctrl.is_jalr ? jalr_sum[1] : in.tgt_misal);

  always_comb begin
    misalign_fault = (branch_taken && in.tgt_misal) || jump_misal_ex;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // ── Next-PC verification ──────────────────────────────────────────────
  // Fetch predicted the pc that now sits in the pc register (fetch_pc).
  // Compare it with the architecturally correct next PC and redirect only
  // on a mismatch. The BTB may predict any control type, JALR included
  // (last target), so JALR is compared like the others. The mismatch is
  // only REGISTERED here (reg_q.redir); MEM applies it one cycle later.
  // The 30-bit compares of the PC-relative / fall-through targets are
  // flop-to-flop and run in parallel with the late forward ->
  // branch-condition chain.
  //   exp_ft : expected next PC is the fall-through (not taken, non-control
  //            instruction, or a misalign trap which keeps the linear PC).
  logic eq_tgt;
  logic eq_ft;
  logic eq_jalr;
  logic actual_taken;
  logic exp_ft;
  logic jalr_go;
  logic [31:0] actual_next;

  always_comb begin
    eq_tgt       = (fetch_pc[31:2] == in.tgt[31:2]);
    eq_ft        = (fetch_pc[31:2] == in.pc_plus4[31:2]);
    eq_jalr      = (fetch_pc[31:2] == jalr_sum[31:2]);
    actual_taken = branch_taken || in.ctrl.is_jump;
    exp_ft       = !actual_taken || misalign_fault;
    jalr_go      = in.ctrl.is_jalr && !misalign_fault;
    actual_next  = jalr_go ? jalr_target : (exp_ft ? in.pc_plus4 : in.tgt);
  end

  // Mismatch with branch_cond (the latest signal) as the final select
  // between two early-resolved outcomes; identical to
  //   ex_valid && (actual_next[31:2] != fetch_pc[31:2]).
  logic tk_early;      // JAL, aligned target (taken regardless of branch_cond)
  logic tk_br;         // branch with aligned target (taken iff branch_cond)
  logic redir_c1;      // mismatch if branch_cond = 1
  logic redir_c0;      // mismatch if branch_cond = 0
  logic redir_d;
  always_comb begin
    tk_early = in.ctrl.is_jump && !in.ctrl.is_jalr && !in.tgt_misal;
    tk_br    = in.ctrl.is_branch && !in.tgt_misal;
    redir_c1 = ex_valid && (jalr_go ? !eq_jalr : ((tk_early || tk_br) ? !eq_tgt : !eq_ft));
    redir_c0 = ex_valid && (jalr_go ? !eq_jalr : (tk_early           ? !eq_tgt : !eq_ft));
    redir_d  = branch_cond ? redir_c1 : redir_c0;
  end

  // ── EX/MEM result select ──────────────────────────────────────────────
  // For JAL/JALR, the rd_wdata is PC+4 (return address), not the ALU's
  // sum (which is the jump target). The MEM/WB register's read-data mux
  // only kicks in for LOADs, so we route PC+4 here. The jump and MUL/DIV
  // legs are merged: the select and the alternate value depend only on
  // ID/EX / muldiv flops, so just one 2:1 level follows the ALU result.
  logic        alt_sel;
  logic [31:0] alt_val;
  logic [31:0] result_sel;

  always_comb begin
    alt_sel    = in.ctrl.is_jump || md_op;
    alt_val    = in.ctrl.is_jump ? in.pc_plus4 : md_result;
    result_sel = alt_sel ? alt_val : alu_result;
  end

  assign ex_result = result_sel;

  // ── EX/MEM register ───────────────────────────────────────────────────
  // A bubble (md_stall) clears only valid + ctrl; the data fields are plain
  // CE flops (they are never consumed without valid / ctrl qualification).
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      // dmem stall: hold the EX/MEM register so the in-flight LOAD/STORE
      // stays in MEM stage waiting on the bus.
      reg_q <= reg_q;
    end else if (md_stall || reg_q.redir) begin
      // MUL/DIV still computing: it stays in EX, MEM sees a bubble
      // (valid=0, ctrl=0 so reg_write=0 and forwarding sees nothing).
      // Likewise the wrong-path instruction in EX behind a redirecting
      // MEM instruction (reg_q.redir) is squashed into a bubble; redir
      // is consumed (cleared) either way.
      reg_q.valid <= 1'b0;
      reg_q.ctrl  <= '0;
      reg_q.redir <= 1'b0;
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= result_sel;
      reg_q.write_data    <= in.rs2_val;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // RVFI-only: the post-forward register values captured in ID/EX (held
      // unchanged while a MUL/DIV stalls in EX).
      reg_q.rs1_val       <= in.rs1_val;
      reg_q.rs2_val       <= in.rs2_val;
      // pc_next is the architectural next PC (also the late-redirect
      // target when redir is set). It reverts to pc+4 on misalign trap so
      // the pc_fwd checker (asserting next retirement's pc_rdata == this
      // pc_wdata) stays consistent with the linear PC.
      reg_q.pc_next       <= actual_next;
      reg_q.branch_taken  <= branch_taken;
      // BTB training target: the JALR sum for JALR (last-target
      // prediction), the PC-relative target otherwise.
      reg_q.branch_target <= in.ctrl.is_jalr ? jalr_target : in.tgt;
      reg_q.redir         <= redir_d;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
