// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// The flip-flop regfile is read combinationally here and two younger
// writers are merged in (x0 excluded by the registered w_ok / w_en bits):
//   rs_reg = hit_m ? m_data : (hit_w ? w_data : rf_rd)
//   hit_m : the instruction in MEM this cycle (EX/MEM.rd / w_ok flops vs
//           the raw rs field); m_data is MEM's merged result, the LAST
//           select (m_data = m_nl | m_ld_data, never both nonzero; the
//           late DO-derived load data is the final AND-OR term)
//   hit_w : the regfile write of this cycle (w_q, write-first bypass)
// so ID/EX.rs?_val is the architectural register value as of the end of
// MEM of the instruction ahead of the one in EX. ID captures only when
// !stall, which excludes the cycles a LOAD in MEM is dmem-stalled (its
// m_data is not valid then). ID/EX.b_val is the ALU B operand: the
// immediate when alu_src is set (sel_b then forced to rf), else the
// bypassed rs2.
//
// Also precomputed here for EX:
//   - br_target = pc + imm (BRANCH / JAL) and its misalign bit imm[1]
//     (the PC is always word-aligned). A JAL whose target is misaligned
//     is turned into a trapping non-jump right here (is_jump=0,
//     reg_write=0, is_illegal=1), so it never redirects.
//   - the registered operand selects (forward_unit), plus the ALU-B
//     variant where alu_src forces the register value (= immediate).
//   - AUIPC: its result is br_target (pc + imm), picked in EX's early
//     group by alu_auipc, so imm / b_val carry the raw immediate and the
//     ALU A operand is always rs1.
//   - link = pc + 4 (IF's shared carry-chain incrementer, IF/ID.pc4), the
//     ALU result-group selects (logic group as a 2-bit op + enable; alu_add
//     cleared for loads so EX/MEM.add_q is 0 for them) and the branch
//     condition code {br_ok, use_lt, inv}.
//
// flush / take_kill are a narrow kill: only valid and the side-effect bits
// (reg_write, mem_read, mem_write, is_branch, is_jump, is_div, is_mul,
// br_ok, lu_arm) are cleared.
//
// Flops with several timing-critical consumers in EX (operand selects,
// adder sub / carry-in) are duplicated per consumer with syn_preserve.
// The rest of ID/EX is don't-care in a bubble and has no reset; its only
// enable is !stall.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,      // jump / load-use kill (!dmem_stall)
  input  logic [1:0]        take_kill,  // taken branch in EX && !dmem_stall
                                        // (one copy per 5 kill bits)
  input  if_id_t  in,
  // fetch prediction applied to this instruction's successor (fetch_pred)
  input  logic              pq,
  input  logic [13:0]       pq_off,
  input  logic [9:0]        pk_idx,
  input  logic              pk_tm,
  input  logic [1:0]        pk_ctr,
  input  logic              pk_v,
  // next-cycle forwarding selects (forward_unit)
  input  opsel_t            sel_rs1,
  input  opsel_t            sel_rs2,
  // instruction in MEM this cycle (EX/MEM flops) and its merged result
  input  logic              m_ok,       // EX/MEM.w_ok (reg_write, rd != 0)
  input  logic [4:0]        m_rd,       // EX/MEM.rd
  input  logic [31:0]       m_nl,       // MEM result, non-load half (0 for loads)
  input  logic [31:0]       m_ld_data,  // MEM load data (0 unless LOAD)
  // regfile write port this cycle (write-first bypass of the ID read;
  // w_en excludes x0)
  input  logic              w_en,
  input  logic [4:0]        w_addr,
  input  logic [31:0]       w_data,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  logic [4:0]  dec_alu_op;
  logic        dec_alu_src;
  logic [2:0]  dec_branch_op;
  logic        dec_is_branch;
  logic        dec_is_jump;
  logic        dec_is_jalr;
  logic        dec_is_lui;
  logic        dec_is_auipc;
  logic        dec_mem_read;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;
  logic        dec_is_div;
  logic        dec_is_illegal;

  decoder u_decoder (
    .instr      (in.instr),
    .alu_op     (dec_alu_op),
    .alu_src    (dec_alu_src),
    .branch_op  (dec_branch_op),
    .is_branch  (dec_is_branch),
    .is_jump    (dec_is_jump),
    .is_jalr    (dec_is_jalr),
    .is_lui     (dec_is_lui),
    .is_auipc   (dec_is_auipc),
    .mem_read   (dec_mem_read),
    .mem_write  (dec_mem_write),
    .mem_width  (dec_mem_width),
    .mem_sext   (dec_mem_sext),
    .reg_write  (dec_reg_write),
    .mem_to_reg (dec_mem_to_reg),
    .is_div     (dec_is_div),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the raw IF/ID instruction —
  // also wired to the hazard / forward units at top level.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  logic        dec_is_mul;
  logic        jal_misalign;
  logic [31:0] pc_imm;
  logic [4:0]  alu_op;
  opsel_t      sel_b;
  ctrl_t       ctrl_decoded;
  logic        hit_m1;
  logic        hit_m2;
  logic        hit_mb;
  logic        hit_w1;
  logic        hit_w2;
  logic [31:0] rs1_old;
  logic [31:0] rs2_old;
  logic [31:0] b_old;
  logic [31:0] rs1_reg;
  logic [31:0] rs2_reg;
  logic [31:0] b_reg;
  always_comb begin
    pc_imm  = in.pc + imm;
    alu_op  = dec_alu_op;

    // Bypass of the regfile read (x0 never hits: m_ok / w_en exclude it).
    hit_m1  = m_ok && m_rd   == rs1_addr;
    hit_m2  = m_ok && m_rd   == rs2_addr;
    hit_mb  = hit_m2 && !dec_alu_src;
    hit_w1  = w_en && w_addr == rs1_addr;
    hit_w2  = w_en && w_addr == rs2_addr;
    rs1_old = hit_w1 ? w_data : rs1_data;
    rs2_old = hit_w2 ? w_data : rs2_data;
    b_old   = dec_alu_src ? imm : rs2_old;
    // MEM result last: hit_m ? (m_nl | m_ld_data) : old, where m_nl is 0
    // for a load and m_ld_data 0 otherwise, so the DO-derived load data
    // is the final AND-OR term.
    rs1_reg = (hit_m1 ? m_nl : rs1_old) | ({32{hit_m1}} & m_ld_data);
    rs2_reg = (hit_m2 ? m_nl : rs2_old) | ({32{hit_m2}} & m_ld_data);
    b_reg   = (hit_mb ? m_nl : b_old)   | ({32{hit_mb}} & m_ld_data);

    sel_b = sel_rs2;
    if (dec_alu_src) sel_b.rf = 1'b1;

    // Only the R-type M arm of the decoder emits a MUL* alu_op.
    dec_is_mul   = (dec_alu_op == ALU_MUL)   || (dec_alu_op == ALU_MULH) ||
                   (dec_alu_op == ALU_MULHU) || (dec_alu_op == ALU_MULHSU);
    jal_misalign = dec_is_jump && !dec_is_jalr && imm[1];

    ctrl_decoded.alu_op     = alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch && in.valid;
    ctrl_decoded.is_jump    = dec_is_jump   && in.valid && !jal_misalign;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.is_auipc   = dec_is_auipc;
    ctrl_decoded.mem_read   = dec_mem_read  && in.valid;
    ctrl_decoded.mem_write  = dec_mem_write && in.valid;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write && in.valid && !jal_misalign;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_div     = dec_is_div    && in.valid;
    ctrl_decoded.is_mul     = dec_is_mul    && in.valid;
    ctrl_decoded.is_illegal = dec_is_illegal || jal_misalign;
  end

  // ── Prediction verify (raw instruction bits + flops, no adder) ─────────
  // IF already fetched pc + sext(pq_off) after this instruction when pq is
  // set. It is right only for a BRANCH / aligned JAL whose imm[15:2] is
  // pq_off (and whose offset fits those bits):
  //   p_ok_br  : EX takes the branch iff it is NOT taken (br_inv_t), to link
  //   p_ok_jal : no redirect (is_jump kill bit cleared)
  //   p_bad    : anything else -> "jump" to link in EX (a taken p_bad
  //              branch is overridden by take -> br_target, p_ok = 0)
  logic [13:0] b_off;
  logic [13:0] j_off;
  logic        b_match;
  logic        j_fits;
  logic        j_match;
  logic        dec_is_jal;
  logic        p_ok_br;
  logic        p_ok_jal;
  logic        p_bad;
  logic        tr_en;

  always_comb begin
    b_off      = {{4{in.instr[31]}}, in.instr[7], in.instr[30:25],
                  in.instr[11:9]};
    j_off      = {in.instr[15:12], in.instr[20], in.instr[30:22]};
    j_fits     = (in.instr[31] == in.instr[15]) &&
                 (in.instr[19:16] == {4{in.instr[15]}});
    b_match    = (b_off == pq_off) && !in.instr[8];
    j_match    = (j_off == pq_off) && !in.instr[21] && j_fits;
    dec_is_jal = dec_is_jump && !dec_is_jalr;
    p_ok_br    = pq && ctrl_decoded.is_branch && b_match;
    p_ok_jal   = pq && dec_is_jal && in.valid && j_match;
    p_bad      = pq && in.valid && !p_ok_br && !p_ok_jal &&
                 !(dec_is_jump && !jal_misalign);
    // Allocate only offsets that fit off[15:2] with imm[1] == 0.
    tr_en      = in.instr[3] ? (j_fits && !in.instr[21]) : !in.instr[8];
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // Duplicated flops (syn_preserve: synthesis must not merge them). One
  // operand-select copy per EX operand-mux copy, and the adder's sub bit
  // split into the b-XOR copy and the carry-in copy (fanout 1).
  logic       sel_a_lo_q   /* synthesis syn_preserve=1 */;
  logic       sel_a_hi_q   /* synthesis syn_preserve=1 */;
  logic       sel_a_sll_q  /* synthesis syn_preserve=1 */;
  logic       sel_a_sr_q   /* synthesis syn_preserve=1 */;
  logic       sel_a_cmp_q  /* synthesis syn_preserve=1 */;
  logic       sel_r2_lo_q  /* synthesis syn_preserve=1 */;
  logic       sel_r2_hi_q  /* synthesis syn_preserve=1 */;
  logic       sel_r2_cmp_q /* synthesis syn_preserve=1 */;
  logic       sel_b_lo_q   /* synthesis syn_preserve=1 */;
  logic       sel_b_hi_q   /* synthesis syn_preserve=1 */;
  logic       sel_b_shl_q  /* synthesis syn_preserve=1 */;
  logic       sel_b_shr_q  /* synthesis syn_preserve=1 */;
  logic       alu_sub_q    /* synthesis syn_preserve=1 */;
  logic       alu_cin_q    /* synthesis syn_preserve=1 */;
  logic       p_ok_lo_q    /* synthesis syn_preserve=1 */;
  logic       p_ok_hi_q    /* synthesis syn_preserve=1 */;
  logic       dec_sub;

  assign dec_sub = alu_op == ALU_SUB || alu_op == ALU_SLT || alu_op == ALU_SLTU;

  always_ff @(posedge clock) begin
    if (!stall) begin
      sel_a_lo_q   <= sel_rs1;
      sel_a_hi_q   <= sel_rs1;
      sel_a_sll_q  <= sel_rs1;
      sel_a_sr_q   <= sel_rs1;
      sel_a_cmp_q  <= sel_rs1;
      sel_r2_lo_q  <= sel_rs2;
      sel_r2_hi_q  <= sel_rs2;
      sel_r2_cmp_q <= sel_rs2;
      sel_b_lo_q   <= sel_b;
      sel_b_hi_q   <= sel_b;
      sel_b_shl_q  <= sel_b;
      sel_b_shr_q  <= sel_b;
      alu_sub_q    <= dec_sub;
      alu_cin_q    <= dec_sub;
      p_ok_lo_q    <= p_ok_br;
      p_ok_hi_q    <= p_ok_br;
    end
  end

  // Data / non-side-effect fields: no reset, enable = !stall.
  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pc              <= in.pc;
      reg_q.rs1_val         <= rs1_reg;
      reg_q.rs2_val         <= rs2_reg;
      reg_q.b_val           <= b_reg;
      reg_q.imm             <= imm;
      reg_q.link            <= in.pc4;
      reg_q.br_target       <= pc_imm;
      reg_q.br_misalign     <= imm[1];
      // Operand selects / alu_sub / alu_cin: overridden by the
      // syn_preserve copies above.
      reg_q.sel_a_lo        <= '0;
      reg_q.sel_a_hi        <= '0;
      reg_q.sel_a_sll       <= '0;
      reg_q.sel_a_sr        <= '0;
      reg_q.sel_a_cmp       <= '0;
      reg_q.sel_r2_lo       <= '0;
      reg_q.sel_r2_hi       <= '0;
      reg_q.sel_r2_cmp      <= '0;
      reg_q.sel_b_lo        <= '0;
      reg_q.sel_b_hi        <= '0;
      reg_q.sel_b_shl       <= '0;
      reg_q.sel_b_shr       <= '0;
      // ALU result groups. Jumps / divs / AUIPC take link / div_result /
      // br_target; their alu_op is ADD / DIV* and must not also select
      // the adder. Loads (alu_op ADD) clear it too, so EX/MEM.add_q is 0
      // and MEM ORs it in without a select.
      reg_q.alu_add         <= (alu_op == ALU_ADD || alu_op == ALU_SUB) &&
                               !dec_is_jump && !dec_is_auipc &&
                               !dec_mem_to_reg;
      reg_q.alu_slt         <= alu_op == ALU_SLT || alu_op == ALU_SLTU;
      reg_q.alu_sll         <= alu_op == ALU_SLL;
      reg_q.alu_sr          <= alu_op == ALU_SRL || alu_op == ALU_SRA;
      // Logic group: 00 AND, 01 OR, 10 XOR, 11 pass b (LUI).
      reg_q.alu_logic       <= alu_op == ALU_AND || alu_op == ALU_OR ||
                               alu_op == ALU_XOR || alu_op == ALU_LUI;
      reg_q.alu_lop         <= {alu_op == ALU_XOR || alu_op == ALU_LUI,
                                alu_op == ALU_OR  || alu_op == ALU_LUI};
      reg_q.alu_link        <= dec_is_jump;
      reg_q.alu_div         <= dec_is_div;
      reg_q.alu_auipc       <= dec_is_auipc;
      reg_q.alu_sub         <= 1'b0;   // overridden by alu_sub_q
      reg_q.alu_cin         <= 1'b0;   // overridden by alu_cin_q
      reg_q.alu_arith       <= alu_op == ALU_SRA;
      reg_q.alu_uns         <= alu_op == ALU_SLTU;
      // MUL: operand extension enables and MEM result selects (gated in
      // EX/MEM with reg_write / is_mul where it matters).
      reg_q.mul_a_sgn       <= alu_op == ALU_MULH || alu_op == ALU_MULHSU;
      reg_q.mul_b_sgn       <= alu_op == ALU_MULH;
      reg_q.mul_lo          <= alu_op == ALU_MUL;
      reg_q.mul_hi          <= alu_op == ALU_MULH || alu_op == ALU_MULHU ||
                               alu_op == ALU_MULHSU;
      reg_q.lu_arm          <= 1'b0;   // overridden by kill_q below
      // Branch condition (funct3): 0 BEQ, 1 BNE, 4/6 BLT(U), 5/7 BGE(U).
      // cond = (use_lt ? lt : eq) ^ inv.
      reg_q.br_use_lt       <= dec_branch_op[2];
      reg_q.br_inv          <= dec_branch_op[0];
      reg_q.br_uns          <= dec_branch_op[1];
      reg_q.br_ok           <= 1'b0;   // overridden by kill_q below
      // Fetch prediction: take fires on a misprediction of a verified
      // predicted-taken branch too (br_inv_t), to link (p_ok copies).
      reg_q.br_inv_t        <= dec_branch_op[0] ^ p_ok_br;
      reg_q.p_ok_lo         <= 1'b0;   // overridden by p_ok_lo_q
      reg_q.p_ok_hi         <= 1'b0;   // overridden by p_ok_hi_q
      reg_q.jlink           <= dec_is_jalr || p_bad;
      reg_q.arch_jump       <= dec_is_jump && !jal_misalign;
      reg_q.p_bad           <= p_bad;
      reg_q.tr_jal          <= dec_is_jal && !jal_misalign;
      reg_q.tr_en           <= tr_en;
      reg_q.pk_idx          <= pk_idx;
      reg_q.pk_tm           <= pk_tm;
      reg_q.pk_ctr          <= pk_ctr;
      reg_q.pk_v            <= pk_v;
      reg_q.rd              <= in.instr[11:7];
      reg_q.rs1_addr        <= in.instr[19:15];
      reg_q.rs2_addr        <= in.instr[24:20];
      // valid and the side-effect ctrl bits are overridden by kill_q below.
      reg_q.ctrl            <= ctrl_decoded;
      reg_q.instr           <= in.instr;
      reg_q.valid           <= in.valid;
    end
  end

  // Valid + side-effect bits: reset / narrow kill, else enable = !stall.
  // {lu_arm, br_ok, valid, reg_write, mem_read, mem_write, is_branch,
  //  is_jump, is_div, is_mul}
  // lu_arm = (mem_read | is_mul) && rd != 0 arms the 1-bubble interlock in
  // hazard_unit, so its load-use term is lu_arm & (rd == rs1 | rd == rs2).
  // kill_nt is the next state without the taken-branch kill (reset, jump /
  // load-use flush, stall hold, capture). The taken branch (take_kill,
  // already gated by !dmem_stall in EX) is the last term, a D-input AND
  // rather than a synchronous reset driven by the redirect.
  logic [9:0] kill_q;
  logic [9:0] kill_nt /* synthesis syn_keep=1 */;
  logic [9:0] kill_d;

  always_comb begin
    if (reset || flush) begin
      kill_nt = 10'b0;
    end else if (stall) begin
      kill_nt = kill_q;
    end else begin
      kill_nt = {(ctrl_decoded.mem_read || ctrl_decoded.is_mul) &&
                   in.instr[11:7] != 5'b0,
                 ctrl_decoded.is_branch && !imm[1],
                 in.valid,
                 ctrl_decoded.reg_write, ctrl_decoded.mem_read,
                 ctrl_decoded.mem_write, ctrl_decoded.is_branch,
                 (ctrl_decoded.is_jump && !p_ok_jal) || p_bad,
                 ctrl_decoded.is_div,
                 ctrl_decoded.is_mul};
    end
    kill_d = kill_nt & ~{{5{take_kill[1]}}, {5{take_kill[0]}}};
  end

  always_ff @(posedge clock) begin
    kill_q <= kill_d;
  end

  always_comb begin
    out                = reg_q;
    out.sel_a_lo       = sel_a_lo_q;
    out.sel_a_hi       = sel_a_hi_q;
    out.sel_a_sll      = sel_a_sll_q;
    out.sel_a_sr       = sel_a_sr_q;
    out.sel_a_cmp      = sel_a_cmp_q;
    out.sel_r2_lo      = sel_r2_lo_q;
    out.sel_r2_hi      = sel_r2_hi_q;
    out.sel_r2_cmp     = sel_r2_cmp_q;
    out.sel_b_lo       = sel_b_lo_q;
    out.sel_b_hi       = sel_b_hi_q;
    out.sel_b_shl      = sel_b_shl_q;
    out.sel_b_shr      = sel_b_shr_q;
    out.alu_sub        = alu_sub_q;
    out.alu_cin        = alu_cin_q;
    out.p_ok_lo        = p_ok_lo_q;
    out.p_ok_hi        = p_ok_hi_q;
    out.lu_arm         = kill_q[9];
    out.br_ok          = kill_q[8];
    out.valid          = kill_q[7];
    out.ctrl.reg_write = kill_q[6];
    out.ctrl.mem_read  = kill_q[5];
    out.ctrl.mem_write = kill_q[4];
    out.ctrl.is_branch = kill_q[3];
    out.ctrl.is_jump   = kill_q[2];
    out.ctrl.is_div    = kill_q[1];
    out.ctrl.is_mul    = kill_q[0];
  end

endmodule
