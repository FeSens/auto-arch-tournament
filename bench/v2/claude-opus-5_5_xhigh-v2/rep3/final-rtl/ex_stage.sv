// rtl/ex_stage.sv
//
// Execute stage. Applies the single EX/MEM -> EX bypass, runs the ALU,
// resolves branches, computes the redirect target. Owns the EX/MEM
// pipeline register.
//
// Operands arrive resolved from ID (MEM-stage producer and regfile
// write-first already applied). The only bypass left is the ID/EX
// occupant's immediate predecessor in EX/MEM: a 2:1 mux per operand with
// a registered select (fwd1_ex / fwd2_ex / fwdb_ex). The late reg_write
// clear on a misaligned jump is folded into those selects in ID via
// ex_wb_kill, so no EX/MEM.reg_write qualifier is needed here.
//
// pc + imm, pc + 4 and the LUI / AUIPC / link result are precomputed in
// ID; the ALU result is a flat one-hot AND-OR (RS_PRE covers the
// ID-precomputed value).
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
  output logic               redirect,
  output logic               redirect_ce,   // same logic, PC-enable copy
  output logic [31:0]        redirect_target,
  output logic               ex_wb_kill,    // ID/EX occupant's reg_write is cleared
  output logic               div_stall      // DIV* in EX, result not ready
);

  ex_mem_t reg_q;

  // ── EX/MEM -> EX bypass ───────────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;
  logic [31:0] alu_b;

  always_comb begin
    rs1   = in.fwd1_ex ? reg_q.alu_result : in.rs1_val;
    rs2   = in.fwd2_ex ? reg_q.alu_result : in.rs2_val;
    alu_b = in.fwdb_ex ? reg_q.alu_result : in.op_b;
  end

  // ── Iterative divide handshake ────────────────────────────────────────
  // A DIV* in EX holds ID/EX + PC (via hazard_unit) and feeds bubbles into
  // EX/MEM until the divider reports done. The divider latches the
  // post-bypass operands on div_start because the producer drains out of
  // EX/MEM while the DIV waits; rs1/rs2 are also latched here raw so RVFI
  // rs1_rdata/rs2_rdata stay correct.
  logic        is_div;
  logic        div_start;
  logic        div_ack;
  logic        div_busy;
  logic        div_done;
  logic [31:0] div_rs1_q;
  logic [31:0] div_rs2_q;

  always_comb begin
    is_div    = in.valid && in.alu_sel[RS_DIV];
    div_stall = is_div && !div_done;
    div_start = div_stall && !div_busy;
    div_ack   = is_div && div_done && !stall;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      div_rs1_q <= 32'b0;
      div_rs2_q <= 32'b0;
    end else if (div_start) begin
      div_rs1_q <= rs1;
      div_rs2_q <= rs2;
    end
  end

  logic [31:0] alu_result;
  alu u_alu (
    .clock       (clock),
    .reset       (reset),
    .op          (in.ctrl.alu_op),
    .sel         (in.alu_sel),
    .shift_arith (in.shift_arith),
    .a_signed    (in.a_signed),
    .b_signed    (in.b_signed),
    .pre         (in.pre_result),
    .a           (rs1),
    .b           (alu_b),
    .div_start   (div_start),
    .div_ack     (div_ack),
    .div_busy    (div_busy),
    .div_done    (div_done),
    .out         (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        branch_cond;
  logic        branch_taken;
  // rs1 + imm: JALR target (bit 0 dropped per RV spec) and the dedicated
  // LOAD/STORE AGU feeding EX/MEM.mem_addr (-> dmem address).
  logic [31:0] jalr_sum;
  logic        br_eq;
  logic        br_lt;

  always_comb begin
    // One comparator chain: 33-bit signed less-than whose extension bit
    // is the sign bit for BLT/BGE and 0 for BLTU/BGEU.
    br_eq       = (rs1 == rs2);
    br_lt       = $signed({rs1[31] & ~in.br_uns, rs1})
                < $signed({rs2[31] & ~in.br_uns, rs2});
    branch_cond = (in.br_use_lt ? br_lt : br_eq) ^ in.br_inv;
    branch_taken = (in.br_ok || in.br_bad) && branch_cond;
    jalr_sum     = rs1 + in.imm;
  end

  // ── Misaligned branch / jump target trap ──────────────────────────────
  // riscv-formal's spec demands rvfi_trap=1 when next_pc is misaligned
  // (without C extension that means [1:0] != 0). We trap the offending
  // instruction, suppress the redirect (PC stays linear), and clear
  // reg_write so JAL/JALR don't write the return address on trap.
  // PC[1:0] is always 0 (if_stage) and B/J immediates have imm[0] = 0, so
  // a branch/JAL target is misaligned iff imm[1]. JALR needs bit 1 of
  // rs1 + imm (bit 0 is cleared by the spec).
  // The imm[1] part is pre-decoded in ID (br_ok/br_bad, jal_ok/jal_bad),
  // so the redirect is one AND-OR after the compare and the trap terms
  // feed only EX/MEM flops and ex_wb_kill, not the PC enable.
  logic misalign_jump;
  logic misalign_fault;
  logic jalr_bit1;
  logic mem_misalign;
  ctrl_t ctrl_with_trap;

  always_comb begin
    jalr_bit1       = rs1[1] ^ in.imm[1] ^ (rs1[0] & in.imm[0]);
    misalign_jump   = in.jal_bad || (in.jalr_np && jalr_bit1);
    misalign_fault  = (in.br_bad && branch_cond) || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end

    // Same misalign rule as mem_stage, on the AGU result: a misaligned
    // LOAD never writes rd, so it must not forward to ID.
    mem_misalign = (in.ctrl.mem_width == 2'd2 && jalr_sum[1:0] != 2'b00) ||
                   (in.ctrl.mem_width == 2'd1 && jalr_sum[0]   != 1'b0);
  end

  // Branches never write rd, so only the jump part of the fault clears a
  // forwardable reg_write.
  // redirect_ce is a kept duplicate that drives only the PC enable, so the
  // PC CE net and the PC D-mux / flush_id nets are driven separately.
  (* syn_keep = 1 *) logic redirect_d;   // PC D-mux / flush_id copy
  (* syn_keep = 1 *) logic redirect_e;   // PC enable copy
  // BTB: branch_cond already has the prediction folded into br_inv, so a
  // branch redirects on mispredict. early covers unpredicted / wrongly
  // predicted JAL and every bad prediction (replay refetches pc).
  (* syn_keep = 1 *) logic [31:0] e_tgt;
  assign e_tgt           = in.replay ? in.pc : in.jfix ? in.pc_imm : in.alt_pc;
  assign redirect_d      = (in.br_ok && branch_cond) || in.early ||
                           (in.jalr_np && !jalr_bit1);
  assign redirect_e      = (in.br_ok && branch_cond) || in.early ||
                           (in.jalr_np && !jalr_bit1);
  assign ex_wb_kill      = misalign_jump;
  assign redirect        = redirect_d;
  assign redirect_ce     = redirect_e;
  assign redirect_target = in.jalr_np ? {jalr_sum[31:1], 1'b0} : e_tgt;

  // Architectural next PC (RVFI only; pruned in synthesis): a correctly
  // predicted branch / JAL continues at pc_imm without a redirect.
  logic [31:0] arch_next;
  assign arch_next = redirect ? redirect_target
                   : (in.pt && (in.br_ok || in.jfix)) ? in.pc_imm : in.pc4;

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
      // JAL/JALR's link value (pc + 4) arrives via RS_PRE.
      reg_q.alu_result    <= alu_result;
      reg_q.mem_addr      <= jalr_sum;
      reg_q.write_data    <= is_div ? div_rs2_q : rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      reg_q.rs1_val       <= is_div ? div_rs1_q : rs1;
      reg_q.rs2_val       <= is_div ? div_rs2_q : rs2;
      // pc_next reverts to pc+4 on misalign trap so the pc_fwd checker
      // (asserting next retirement's pc_rdata == this pc_wdata) stays
      // consistent with the suppressed redirect.
      reg_q.pc_next       <= arch_next;
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= in.pc_imm;
      reg_q.ctrl          <= ctrl_with_trap;
      reg_q.fwd_ok        <= in.ctrl.reg_write && !misalign_jump && in.rd != 5'b0 &&
                             !((in.ctrl.mem_read || in.ctrl.mem_write) && mem_misalign);
      reg_q.instr         <= in.instr;
      // A replayed branch/JALR is killed here (its reg_write was already
      // cleared in ID) and refetched.
      reg_q.valid         <= in.valid && !in.replay;
      // BTB training fields, flop-sourced (no redirect / cond loads; the
      // branch outcome is read from IF's redir_q next cycle).
      reg_q.t_jal         <= in.valid && in.jfix;
      reg_q.t_br          <= in.br_ok && !in.replay;
      reg_q.t_clr         <= in.valid && in.pt && !in.jfix &&
                             !(in.br_ok && !in.replay);
      reg_q.t_pt          <= in.pt;
      reg_q.t_hit         <= in.hit;
      reg_q.t_ctr         <= in.ctr;
      // Divide in progress: EX/MEM takes a bubble so MEM/WB drain.
      if (div_stall) begin
        reg_q.valid          <= 1'b0;
        reg_q.ctrl.reg_write <= 1'b0;
        reg_q.ctrl.mem_read  <= 1'b0;
        reg_q.ctrl.mem_write <= 1'b0;
        reg_q.fwd_ok         <= 1'b0;
        reg_q.t_jal          <= 1'b0;
        reg_q.t_br           <= 1'b0;
        reg_q.t_clr          <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
