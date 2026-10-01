// rtl/ex_stage.sv
//
// Execute stage. Resolves the operand muxes (forwarding from EX/MEM and
// MEM/WB), runs the ALU, resolves branches, computes the redirect
// target. Owns the EX/MEM pipeline register.
//
// Forwarding: the rd comparisons, the reg_write qualification and the
// priority (EX/MEM > MEM/WB > ID value) are resolved in ID and arrive as
// registered one-hot selects in ID/EX (s?_ex / s?_wb / s?_rf), so every
// operand mux is a flop-selected AND-OR. The MEM/WB source is a
// forward-only copy of MEM/WB.wb_data (mem_stage fwd_wb).
//
// A dedicated AGU (rs1 + imm) feeds EX/MEM.mem_addr, which alone drives
// the dmem address and byte lanes, so the dmem path skips the ALU result
// mux. JAL/JALR get their link address (pc + 4) out of the ALU itself
// (ID pre-selects operand a = pc, operand b = 4), so there is no link
// mux after the ALU.
//
// Latency:        1 cycle (EX/MEM register clocked here).
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  input  id_ex_t   in,
  input  logic [31:0]        fwd_ex_mem,    // EX/MEM.alu_result (registered)
  input  logic [31:0]        fwd_mem_wb,    // forward-only copy of MEM/WB.wb_data
  // Fetch-override cycle (registered redirect pending in IF): the
  // instruction in EX is wrong-path. EX/MEM captures it as a bubble, and
  // its redirect, BHT training and divide start are suppressed.
  input  logic               kill,
  output ex_mem_t  out,
  output logic               redirect,       // sets IF's ovr_q flop
  output logic [31:2]        redirect_target,
  output logic               div_stall,     // DIV* in EX not finished yet
  // reg_write as EX/MEM will capture it (misaligned JAL/JALR cleared);
  // ID qualifies its registered forward selects with it.
  output logic               ex_rw_next,
  // BHT training port (flops) into if_stage
  output logic               bht_we,
  output logic [8:0]         bht_widx,
  output logic [1:0]         bht_wdata
);

  // ── Operand forwarding muxes ───────────────────────────────────────────
  logic [31:0] rs1;
  logic [31:0] rs2;

  // One-hot, flop-driven selects (priority and reg_write qualification
  // were resolved in ID).
  always_comb begin
    rs1 = ({32{in.s1_ex}} & fwd_ex_mem) | ({32{in.s1_wb}} & fwd_mem_wb) |
          ({32{in.s1_rf}} & in.rs1_val);
    rs2 = ({32{in.s2_ex}} & fwd_ex_mem) | ({32{in.s2_wb}} & fwd_mem_wb) |
          ({32{in.s2_rf}} & in.rs2_val);
  end

  // ── ALU operands ──────────────────────────────────────────────────────
  // pc / immediate were pre-selected in ID (opa_val / opb_val); sa_* /
  // sb_* already have the forward arms masked off for those operands, so
  // this is a plain one-hot AND-OR on flop-sourced data.
  logic [31:0] alu_a;
  logic [31:0] alu_b;
  always_comb begin
    alu_a = ({32{in.sa_ex}} & fwd_ex_mem) | ({32{in.sa_wb}} & fwd_mem_wb) |
            ({32{in.sa_rf}} & in.opa_val);
    alu_b = ({32{in.sb_ex}} & fwd_ex_mem) | ({32{in.sb_wb}} & fwd_mem_wb) |
            ({32{in.sb_rf}} & in.opb_val);
  end

  // ── AGU: load/store effective address (also the JALR target sum) ──────
  logic [31:0] agu_sum;
  assign agu_sum = rs1 + in.imm;

  // ── Iterative divider ─────────────────────────────────────────────────
  // DIV/DIVU/REM/REMU wait in ID/EX (front of the pipe held via
  // hazard_unit) while div_unit iterates; EX/MEM captures bubbles until
  // div_done. The unit latches the post-forward operands on start, since
  // the forwarding sources drain away during the stall. It holds the
  // result in DONE until EX/MEM actually advances (!stall).
  logic        div_valid;
  logic        div_done;
  logic [31:0] div_result;   // 0 unless div_done (see div_unit.sv)
  logic [31:0] div_a_q;
  logic [31:0] div_b_q;

  assign div_valid = in.valid && in.ctrl.is_div && !kill;

  div_unit u_div (
    .clock   (clock),
    .reset   (reset),
    .start   (div_valid),
    .op      (in.instr[13:12]),
    .a       (rs1),
    .b       (rs2),
    .consume (!stall),
    .done    (div_done),
    .result  (div_result),
    .a_q     (div_a_q),
    .b_q     (div_b_q)
  );

  assign div_stall = div_valid && !div_done;

  // JAL/JALR: the ALU computes pc + 4 (opa = pc, opb = 4).
  // DIV*: the ALU emits 0 on its non-MUL side and ORs div_result in there
  // (0 unless div_done), keeping the OR off the multiplier's output path.
  logic [31:0] alu_result;
  alu u_alu (
    .op           (in.ctrl.alu_op),
    .a            (alu_a),
    .b            (alu_b),
    .mul_sel      (in.mul_sel),
    .mul_hi       (in.mul_hi),
    .mul_a_signed (in.mul_a_signed),
    .mul_b_signed (in.mul_b_signed),
    .div_in       (div_result),
    .out          (alu_result)
  );

  // ── Branch resolve ────────────────────────────────────────────────────
  // The PC is always word-aligned (if_stage), so the branch / JAL target
  // low bits are imm[1:0] (imm[0] = 0) and the JALR target's bit 1 is
  // agu_sum[1]. The redirect is a flat AND-OR of the ID-precomputed,
  // alignment-gated selects with the three comparator outputs.
  // agu1 = agu_sum[1] from the low two bits alone (the JALR target's
  // alignment), so ex_rw_next does not wait for the 32-bit carry chain.
  logic        cmp_eq;
  logic        cmp_lt;
  logic        cmp_ltu;
  logic        agu1;
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] jump_target;

  always_comb begin
    cmp_eq  = (rs1 == rs2);
    cmp_lt  = ($signed(rs1) < $signed(rs2));
    cmp_ltu = (rs1 < rs2);
    agu1    = rs1[1] ^ in.imm[1] ^ (rs1[0] & in.imm[0]);
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond =  cmp_eq;
      BR_BNE:  branch_cond = !cmp_eq;
      BR_BLT:  branch_cond =  cmp_lt;
      BR_BGE:  branch_cond = !cmp_lt;
      BR_BLTU: branch_cond =  cmp_ltu;
      BR_BGEU: branch_cond = !cmp_ltu;
      default: branch_cond = 1'b0;
    endcase
    branch_taken  = in.ctrl.is_branch && branch_cond;
    branch_target = in.pc + in.imm;
    // JALR clears bit 0 (RV spec); JAL uses imm directly.
    jump_target = in.ctrl.is_jalr ? {agu_sum[31:1], 1'b0}
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
    misalign_branch = branch_taken && in.imm[1];
    misalign_jump   = in.ctrl.is_jump && (in.ctrl.is_jalr ? agu1
                                                          : in.imm[1]);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // A branch never has reg_write, so misalign_branch never clears it.
  assign ex_rw_next = in.ctrl.reg_write && !misalign_jump;

  // Redirect only on a branch mispredict (the sel_* selects already have
  // the IF prediction folded in) or an aligned JALR. An aligned JAL was
  // predicted taken in IF and never redirects. A mispredicted branch
  // goes to the ID-registered alt_target (pc + 4 or pc + imm), so the
  // pc + imm adder stays off the PC path.
  //
  // The redirect only feeds IF's ovr_q flops (registered redirect); it is
  // qualified with !stall (the branch stays in EX under a dmem stall and
  // redirects when EX/MEM takes it) and !kill (wrong-path EX instruction).
  // The target is captured by IF every non-override cycle, independent of
  // the decision.
  logic redirect_raw;
  assign redirect_raw = (in.sel_eq  &&  cmp_eq)  || (in.sel_ne  && !cmp_eq)  ||
                        (in.sel_lt  &&  cmp_lt)  || (in.sel_ge  && !cmp_lt)  ||
                        (in.sel_ltu &&  cmp_ltu) || (in.sel_geu && !cmp_ltu) ||
                        (in.ctrl.is_jalr && !agu1);
  assign redirect        = redirect_raw && !stall && !kill;
  assign redirect_target = in.ctrl.is_jalr ? agu_sum[31:2]
                                           : in.alt_target[31:2];

  // ── BHT training (registered; written into IF's BHT one cycle late) ───
  // For a valid aligned branch the actual direction is pred ^ redirect
  // (redirect = mispredict). A misaligned branch has no selects, so it
  // trains towards not-taken; it traps anyway.
  logic       br_taken_act;
  logic [1:0] ctr_new;
  always_comb begin
    br_taken_act = in.pred ^ redirect_raw;
    case ({br_taken_act, in.bht_ctr})
      3'b1_00: ctr_new = 2'b01;
      3'b1_01: ctr_new = 2'b10;
      3'b1_10: ctr_new = 2'b11;
      3'b1_11: ctr_new = 2'b11;
      3'b0_00: ctr_new = 2'b00;
      3'b0_01: ctr_new = 2'b00;
      3'b0_10: ctr_new = 2'b01;
      default: ctr_new = 2'b10;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) bht_we <= 1'b0;
    else       bht_we <= in.valid && in.ctrl.is_branch && !stall && !kill;
    bht_widx  <= in.pc[10:2];
    bht_wdata <= ctr_new;
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
    end else begin
      reg_q.pc            <= in.pc;
      reg_q.alu_result    <= alu_result;
      reg_q.mem_addr      <= agu_sum;
      reg_q.write_data    <= rs2;
      reg_q.rd            <= in.rd;
      reg_q.rs1_addr      <= in.rs1_addr;
      reg_q.rs2_addr      <= in.rs2_addr;
      // RVFI: a completing divide reports the operands it latched at
      // start; the live forward muxes may be stale by now.
      reg_q.rs1_val       <= in.ctrl.is_div ? div_a_q : rs1;
      reg_q.rs2_val       <= in.ctrl.is_div ? div_b_q : rs2;
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
      // Divide still running: EX/MEM captures a bubble. A DIV* never
      // sets mem_read/mem_write/is_illegal/is_jump/is_branch, so only
      // valid and reg_write (qualifies forwarding) need clearing.
      if (div_stall) begin
        reg_q.valid          <= 1'b0;
        reg_q.ctrl.reg_write <= 1'b0;
      end
      // Override cycle: the EX instruction is wrong-path (it entered ID/EX
      // behind the redirecting branch/JALR now in EX/MEM). Capture it as a
      // control-cleared bubble. The branch in EX/MEM is never a memory op,
      // so no dmem stall can coincide with the kill.
      if (kill) begin
        reg_q.valid           <= 1'b0;
        reg_q.ctrl.reg_write  <= 1'b0;
        reg_q.ctrl.mem_read   <= 1'b0;
        reg_q.ctrl.mem_write  <= 1'b0;
        reg_q.ctrl.is_branch  <= 1'b0;
        reg_q.ctrl.is_jump    <= 1'b0;
        reg_q.ctrl.is_illegal <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
