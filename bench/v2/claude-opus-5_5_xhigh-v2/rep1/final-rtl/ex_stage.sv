// rtl/ex_stage.sv
//
// Execute stage, split into parallel lanes that merge at one late,
// flop-selected mux:
//   - flat base ALU lanes (add/sub, logic, sll, sr, slt; alu_lanes),
//     divider result, ID-precomputed pre_result (LUI/AUIPC/link):
//     one-hot AND-OR into EX/MEM.alu_result, selects from ID/EX flops.
//   - Multiplier: rs1/rs2 flops (+ ID-registered extension bits) ->
//     DSP -> 64-bit EX/MEM product register (mul_p_out). MEM selects the
//     half; a MUL's consumer right behind it takes a one-cycle
//     mul-use interlock (hazard_unit, ID/EX.late_result).
//   - AGU lane: dedicated rs1 + imm adder into EX/MEM.mem_addr, which
//     alone drives the dmem address / byte mask / misalign check; its low
//     bits also pre-decode the MEM load byte-lane selects.
//   - Branch lane: compare + ID-precomputed branch_target.
//
// Operands: ID/EX.rs1_val/rs2_val are already fully forwarded by the ID
// bypass network (id_stage.sv / forward_unit.sv), so every lane starts
// from a plain flop. `ex_result` (the one-hot AND-OR written into
// EX/MEM.alu_result) and `ex_w_en` (reg_write, cleared on a misaligned
// jump) feed that network's highest-priority source.
//
// DIV/DIVU/REM/REMU run on the sequential divider (rtl/divider.sv). While
// a divide is in EX and not yet done, `ex_busy` holds IF and ID/EX (via
// hazard_unit) and the EX/MEM register captures a bubble so older
// instructions keep draining. ID/EX holds the exact operands for the
// whole divide.
//
// Latency:        1 cycle (EX/MEM register clocked here); 35 cycles for
//                 a divide.
// RVFI fields:    feeds pc_wdata (= pc_next), the rd_wdata path for
//                 ALU and JAL/JALR (PC+4), and the branch resolve.
module ex_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               stall,         // freeze EX/MEM register (dmem stall)
  // in.late_result feeds only the hazard unit (read at top level).
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t   in,
  /* verilator lint_on UNUSEDSIGNAL */
  output ex_mem_t  out,
  output logic [31:0]        ex_result,     // EX result (ID forward source)
  output logic               ex_w_en,       // reg_write, trap-cleared
  output logic               redirect,
  output logic [31:0]        redirect_target,
  output logic               ex_busy,       // divide in EX, result not ready
  output logic [63:0]        mul_p_out      // EX/MEM product register
);

  logic [31:0] rs1;
  logic [31:0] rs2;

  assign rs1 = in.rs1_val;
  assign rs2 = in.rs2_val;

  // ── Base ALU: flat one-hot lanes (selects are ID/EX flops) ────────────
  logic [31:0] alu_b;
  always_comb begin
    alu_b = in.ctrl.alu_src ? in.imm : rs2;
  end

  logic [31:0] base_out;
  alu_lanes u_alu (
    .a        (rs1),
    .b        (alu_b),
    .sel_add  (in.sel_add),
    .sub      (in.sub),
    .lop      (in.lop),
    .sel_sll  (in.sel_sll),
    .sel_sr   (in.sel_sr),
    .sh_arith (in.sh_arith),
    .sel_slt  (in.sel_slt),
    .slt_u    (in.slt_u),
    .out      (base_out)
  );

  // ── Multiplier: flop -> DSP -> EX/MEM product register ────────────────
  // Operands straight from the ID/EX flops (MUL* is R-type, so b = rs2)
  // plus the ID-registered extension bits. The 64-bit product is
  // registered on the EX/MEM enable with no reset so it can pack into
  // the DSP output register; MEM picks the half (mem_stage alu_or_mul).
  logic [63:0] mul_p;
  multiplier u_mul (
    .op   (in.ctrl.alu_op),
    .a_sx (in.mul_a_sx),
    .b_sx (in.mul_b_sx),
    .a    (rs1),
    .b    (rs2),
    .p    (mul_p)
  );

  logic [63:0] mul_p_q;
  always_ff @(posedge clock) begin
    if (!stall) mul_p_q <= mul_p;
  end
  assign mul_p_out = mul_p_q;

  // ── AGU: LOAD/STORE address and JALR target ───────────────────────────
  logic [31:0] agu_sum;
  always_comb begin
    agu_sum = rs1 + in.imm;
  end

  // ── Sequential divider ────────────────────────────────────────────────
  // ctrl.is_div implies valid: IF emits a NOP when !valid, and ID/EX
  // flush/reset zeroes ctrl.
  logic        div_done;
  logic [31:0] div_result;

  divider u_div (
    .clock  (clock),
    .reset  (reset),
    .req    (in.ctrl.is_div),
    .accept (!stall),
    .op     (in.ctrl.alu_op),
    .a      (rs1),
    .b      (rs2),
    /* verilator lint_off PINCONNECTEMPTY */
    .busy   (),
    /* verilator lint_on PINCONNECTEMPTY */
    .done   (div_done),
    .result (div_result)
  );

  assign ex_busy = in.ctrl.is_div && !div_done;

  // ── Late one-hot result select ────────────────────────────────────────
  // Also the ID bypass network's EX source. No mul lane: every select is
  // 0 for MUL*, so its alu_result is 0 and MEM ORs in the product half.
  logic [31:0] result;
  always_comb begin
    result = base_out
           | ({32{in.sel_div}}  & div_result)
           | ({32{in.sel_pre}}  & in.pre_result);
  end

  assign ex_result = result;

  // ── Load byte-lane pre-decode (from the AGU's low bits) ──────────────
  logic [1:0] ld_a;
  logic [1:0] ld_b0_idx;
  logic       ld_b1_lo, ld_b1_hi, ld_hi_word, ld_sx_b1, ld_sx_hi;
  logic [1:0] ld_sgn_idx;
  always_comb begin
    ld_a = agu_sum[1:0];
    case (in.ctrl.mem_width)
      2'd0: begin  // LB/LBU
        ld_b0_idx  = ld_a;
        ld_b1_lo   = 1'b0;
        ld_b1_hi   = 1'b0;
        ld_hi_word = 1'b0;
        ld_sgn_idx = ld_a;
        ld_sx_b1   = in.ctrl.mem_sext;
        ld_sx_hi   = in.ctrl.mem_sext;
      end
      2'd1: begin  // LH/LHU (ld_a[0] = 1 traps in MEM)
        ld_b0_idx  = {ld_a[1], 1'b0};
        ld_b1_lo   = !ld_a[1];
        ld_b1_hi   = ld_a[1];
        ld_hi_word = 1'b0;
        ld_sgn_idx = {ld_a[1], 1'b1};
        ld_sx_b1   = 1'b0;
        ld_sx_hi   = in.ctrl.mem_sext;
      end
      default: begin  // LW
        ld_b0_idx  = 2'd0;
        ld_b1_lo   = 1'b1;
        ld_b1_hi   = 1'b0;
        ld_hi_word = 1'b1;
        ld_sgn_idx = 2'd3;
        ld_sx_b1   = 1'b0;
        ld_sx_hi   = 1'b0;
      end
    endcase
  end

  // ── Branch resolve ────────────────────────────────────────────────────
  logic        cmp_eq, cmp_lt, cmp_ltu;
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] jump_target;

  always_comb begin
    cmp_eq  = (rs1 == rs2);
    cmp_lt  = ($signed(rs1) < $signed(rs2));
    cmp_ltu = (rs1 < rs2);
    case (in.ctrl.branch_op)
      BR_BEQ:  branch_cond =  cmp_eq;
      BR_BNE:  branch_cond = !cmp_eq;
      BR_BLT:  branch_cond =  cmp_lt;
      BR_BGE:  branch_cond = !cmp_lt;
      BR_BLTU: branch_cond =  cmp_ltu;
      BR_BGEU: branch_cond = !cmp_ltu;
      default: branch_cond = 1'b0;
    endcase
    branch_taken = in.ctrl.is_branch && branch_cond;
    // JALR clears bit 0 (RV spec); JAL uses pc + imm (ID-precomputed).
    jump_target  = in.ctrl.is_jalr ? {agu_sum[31:1], 1'b0}
                                   : in.branch_target;
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
                      && (in.branch_target[1:0] != 2'b00);
    misalign_jump   = in.ctrl.is_jump && (jump_target[1:0] != 2'b00);
    misalign_fault  = misalign_branch || misalign_jump;

    ctrl_with_trap = in.ctrl;
    if (misalign_fault) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end
  end

  // Branches never write rd, so only the jump misalign (flop-fed
  // branch_target / low AGU bits) gates the forward enable; the branch
  // compare stays off the ID bypass selects.
  assign ex_w_en         = in.ctrl.reg_write && !misalign_jump;

  // ── Mispredict redirect ───────────────────────────────────────────────
  // The fetch already followed the ID prediction (pred ? pc+imm : pc+4),
  // so EX redirects only when the resolved next PC differs. ID folded
  // pred, funct3 and the branch target alignment into one-hot flags, so
  // the resolve is flag & compare, ORed. JALR always redirects unless its
  // target is misaligned (agu_sum[1], bit 0 is cleared). branch_taken,
  // the misalign trap and pc_next above stay as before (EX/MEM, RVFI).
  assign redirect        = (in.f_eq  &&  cmp_eq)  || (in.f_ne  && !cmp_eq)
                        || (in.f_lt  &&  cmp_lt)  || (in.f_ge  && !cmp_lt)
                        || (in.f_ltu &&  cmp_ltu) || (in.f_geu && !cmp_ltu)
                        || in.f_jal
                        || (in.f_jr  && !agu_sum[1]);
  assign redirect_target = in.ctrl.is_jalr ? {agu_sum[31:1], 1'b0}
                                           : in.alt_target;

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
      // Don't-care for LOAD/STORE: a load is never forwarded from EX/MEM
      // (load-use interlock) and MEM uses mem_addr.
      reg_q.alu_result    <= result;
      reg_q.mem_addr      <= agu_sum;
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
                            : branch_taken      ? in.branch_target
                                                : (in.pc + 32'd4);
      reg_q.branch_taken  <= branch_taken;
      reg_q.branch_target <= in.branch_target;
      reg_q.ctrl          <= ctrl_with_trap;
      // Divide still iterating: bubble into MEM (a div never reads or
      // writes memory, so only reg_write/valid need gating).
      reg_q.ctrl.reg_write <= ctrl_with_trap.reg_write && !ex_busy;
      reg_q.instr         <= in.instr;
      reg_q.valid         <= in.valid && !ex_busy;
      reg_q.sel_mul_lo    <= in.sel_mul_lo;
      reg_q.sel_mul_hi    <= in.sel_mul_hi;
      reg_q.ld_b0_idx     <= ld_b0_idx;
      reg_q.ld_b1_lo      <= ld_b1_lo;
      reg_q.ld_b1_hi      <= ld_b1_hi;
      reg_q.ld_hi_word    <= ld_hi_word;
      reg_q.ld_sgn_idx    <= ld_sgn_idx;
      reg_q.ld_sx_b1      <= ld_sx_b1;
      reg_q.ld_sx_hi      <= ld_sx_hi;
      reg_q.ctr           <= in.ctr;
    end
  end

  assign out = reg_q;

endmodule
