// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID register (if_stage) plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Producers this instruction will see in EX/MEM (= current ID/EX) and
  // MEM/WB (= current EX/MEM) once it reaches EX. Whenever ID/EX captures
  // a real instruction, EX/MEM and MEM/WB both advance the same cycle
  // (every stall that blocks them also holds or bubbles ID/EX), so the
  // matches computed here stay valid for as long as the instruction
  // waits in ID/EX (dmem stall freezes all three; a held DIV* latches its
  // operands on its first EX cycle).
  // ex_rw_next / wb_rw_next are the reg_write values EX/MEM / MEM/WB will
  // capture on that same edge (ID/EX.reg_write && !misalign_jump, and
  // EX/MEM.reg_write && !mem_misalign). A kill (fetch override) coincides
  // with an ID flush, and a divide in progress holds ID/EX, so the other
  // EX/MEM clears never meet a captured select.
  input  logic [4:0]        id_ex_rd,
  input  logic              ex_rw_next,
  input  logic [4:0]        ex_mem_rd,
  input  logic              wb_rw_next,
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
  logic        dec_is_mul;
  logic        dec_mul_hi;
  logic        dec_mul_a_signed;
  logic        dec_mul_b_signed;
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
    .is_mul       (dec_is_mul),
    .mul_hi       (dec_mul_hi),
    .mul_a_signed (dec_mul_a_signed),
    .mul_b_signed (dec_mul_b_signed),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.is_jump    = dec_is_jump;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.is_auipc   = dec_is_auipc;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_div     = dec_is_div;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── Forward selects (registered into ID/EX) ─────────────────────────────
  // Priority-resolved (EX/MEM over MEM/WB over the ID-read value) and
  // qualified with the reg_write bits the producers will carry, so EX
  // only AND-ORs three flop-selected sources.
  logic s1_ex, s1_wb, s1_rf, s2_ex, s2_wb, s2_rf;
  always_comb begin
    s1_ex = ex_rw_next && rs1_addr != 5'b0 && id_ex_rd  == rs1_addr;
    s1_wb = wb_rw_next && rs1_addr != 5'b0 && ex_mem_rd == rs1_addr && !s1_ex;
    s1_rf = !(s1_ex || s1_wb);
    s2_ex = ex_rw_next && rs2_addr != 5'b0 && id_ex_rd  == rs2_addr;
    s2_wb = wb_rw_next && rs2_addr != 5'b0 && ex_mem_rd == rs2_addr && !s2_ex;
    s2_rf = !(s2_ex || s2_wb);
  end

  // ── ALU operand pre-select ──────────────────────────────────────────────
  // The pc / immediate operand choice is known here, so EX only muxes the
  // forwarded value in front of the ALU. The forward matches are masked
  // off for a pc / immediate operand (an AUIPC/JAL/LUI whose rs field
  // aliases a fresh rd must not forward into it).
  logic        use_pc;
  logic        use_imm;
  logic [31:0] alu_imm;
  logic [31:0] opa_val;
  logic [31:0] opb_val;
  logic        sa_ex, sa_wb, sa_rf, sb_ex, sb_wb, sb_rf;
  always_comb begin
    use_pc  = dec_is_auipc || dec_is_jump;
    use_imm = dec_alu_src  || dec_is_jump;
    // JAL/JALR: the ALU produces the link address pc + 4.
    alu_imm = dec_is_jump ? 32'd4 : imm;
    opa_val = use_pc  ? in.pc   : rs1_data;
    opb_val = use_imm ? alu_imm : rs2_data;
    sa_ex   = s1_ex && !use_pc;
    sa_wb   = s1_wb && !use_pc;
    sa_rf   = !(sa_ex || sa_wb);
    sb_ex   = s2_ex && !use_imm;
    sb_wb   = s2_wb && !use_imm;
    sb_rf   = !(sb_ex || sb_wb);
  end

  // ── Mispredict selects ──────────────────────────────────────────────────
  // The PC is always word-aligned (if_stage), so a branch target's low
  // bits are imm[1:0] with imm[0] = 0: the target is aligned iff imm[1] = 0
  // (B-type imm[1] = instr[8]). A misaligned target traps and never
  // redirects (IF never predicts it), so the one-hot condition selects
  // are gated with it here. The IF prediction is folded in: a branch
  // predicted taken redirects (to pc + 4) when its condition is false, so
  // it selects the inverse condition. EX's redirect stays a flat AND-OR
  // of these flops with the comparator outputs. An aligned JAL is always
  // predicted taken, so it never redirects.
  logic br_ok;
  logic pred;
  logic op_eq, op_ne, op_lt, op_ge, op_ltu, op_geu;
  logic sel_eq, sel_ne, sel_lt, sel_ge, sel_ltu, sel_geu;
  always_comb begin
    br_ok   = dec_is_branch && !in.instr[8];
    pred    = in.pred_taken;
    op_eq   = (dec_branch_op == BR_BEQ);
    op_ne   = (dec_branch_op == BR_BNE);
    op_lt   = (dec_branch_op == BR_BLT);
    op_ge   = (dec_branch_op == BR_BGE);
    op_ltu  = (dec_branch_op == BR_BLTU);
    op_geu  = (dec_branch_op == BR_BGEU);
    sel_eq  = br_ok && ((op_eq  && !pred) || (op_ne  && pred));
    sel_ne  = br_ok && ((op_ne  && !pred) || (op_eq  && pred));
    sel_lt  = br_ok && ((op_lt  && !pred) || (op_ge  && pred));
    sel_ge  = br_ok && ((op_ge  && !pred) || (op_lt  && pred));
    sel_ltu = br_ok && ((op_ltu && !pred) || (op_geu && pred));
    sel_geu = br_ok && ((op_geu && !pred) || (op_ltu && pred));
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  // Split in two. Only the control bits that give a bubble architectural
  // effect are cleared by reset / flush (valid, reg_write, mem_read,
  // mem_write, is_branch, is_jump, is_jalr, is_div, is_illegal, the
  // mispredict selects and pred): load-use needs mem_read, ID forwarding
  // needs reg_write, div start needs valid && is_div, redirect / misalign
  // need the branch / jump bits, RVFI needs valid. The datapath fields
  // only obey !stall, which keeps the redirect -> flush fanout small.
  //
  // The IF/ID word is not NOP-muxed when IF/ID is empty (if_stage), so
  // the control flops are also ANDed with in.valid: an empty-IF/ID bubble
  // gets the same all-zero control as a flush, and its data fields
  // (decoded from a garbage word) are don't-care.
  // data_q's control bits (valid, sel_*, pred) are never written: the
  // output takes them from the control flops below.
  /* verilator lint_off UNDRIVEN */
  id_ex_t data_q;
  /* verilator lint_on UNDRIVEN */

  logic v;
  logic valid_q;
  logic reg_write_q, mem_read_q, mem_write_q;
  logic is_branch_q, is_jump_q, is_jalr_q, is_div_q, is_illegal_q;
  logic sel_eq_q, sel_ne_q, sel_lt_q, sel_ge_q, sel_ltu_q, sel_geu_q;
  logic pred_q;

  assign v = in.valid;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid_q      <= 1'b0;
      reg_write_q  <= 1'b0;
      mem_read_q   <= 1'b0;
      mem_write_q  <= 1'b0;
      is_branch_q  <= 1'b0;
      is_jump_q    <= 1'b0;
      is_jalr_q    <= 1'b0;
      is_div_q     <= 1'b0;
      is_illegal_q <= 1'b0;
      sel_eq_q     <= 1'b0;
      sel_ne_q     <= 1'b0;
      sel_lt_q     <= 1'b0;
      sel_ge_q     <= 1'b0;
      sel_ltu_q    <= 1'b0;
      sel_geu_q    <= 1'b0;
      pred_q       <= 1'b0;
    end else if (!stall) begin
      valid_q      <= v;
      reg_write_q  <= v && dec_reg_write;
      mem_read_q   <= v && dec_mem_read;
      mem_write_q  <= v && dec_mem_write;
      is_branch_q  <= v && dec_is_branch;
      is_jump_q    <= v && dec_is_jump;
      is_jalr_q    <= v && dec_is_jalr;
      is_div_q     <= v && dec_is_div;
      is_illegal_q <= v && dec_is_illegal;
      sel_eq_q     <= v && sel_eq;
      sel_ne_q     <= v && sel_ne;
      sel_lt_q     <= v && sel_lt;
      sel_ge_q     <= v && sel_ge;
      sel_ltu_q    <= v && sel_ltu;
      sel_geu_q    <= v && sel_geu;
      pred_q       <= v && pred;
    end
  end

  always_ff @(posedge clock) begin
    if (!stall) begin
      data_q.pc           <= in.pc;
      data_q.rs1_val      <= rs1_data;
      data_q.rs2_val      <= rs2_data;
      data_q.opa_val      <= opa_val;
      data_q.opb_val      <= opb_val;
      data_q.imm          <= imm;
      data_q.s1_ex        <= s1_ex;
      data_q.s1_wb        <= s1_wb;
      data_q.s1_rf        <= s1_rf;
      data_q.s2_ex        <= s2_ex;
      data_q.s2_wb        <= s2_wb;
      data_q.s2_rf        <= s2_rf;
      data_q.sa_ex        <= sa_ex;
      data_q.sa_wb        <= sa_wb;
      data_q.sa_rf        <= sa_rf;
      data_q.sb_ex        <= sb_ex;
      data_q.sb_wb        <= sb_wb;
      data_q.sb_rf        <= sb_rf;
      data_q.mul_sel      <= dec_is_mul;
      data_q.mul_hi       <= dec_mul_hi;
      data_q.mul_a_signed <= dec_mul_a_signed;
      data_q.mul_b_signed <= dec_mul_b_signed;
      data_q.rd           <= in.instr[11:7];
      data_q.rs1_addr     <= in.instr[19:15];
      data_q.rs2_addr     <= in.instr[24:20];
      data_q.ctrl         <= ctrl_decoded;
      data_q.instr        <= in.instr;
      data_q.bht_ctr      <= in.bht_ctr;
      data_q.alt_target   <= in.alt_target;
    end
  end

  always_comb begin
    out                 = data_q;
    out.valid           = valid_q;
    out.ctrl.reg_write  = reg_write_q;
    out.ctrl.mem_read   = mem_read_q;
    out.ctrl.mem_write  = mem_write_q;
    out.ctrl.is_branch  = is_branch_q;
    out.ctrl.is_jump    = is_jump_q;
    out.ctrl.is_jalr    = is_jalr_q;
    out.ctrl.is_div     = is_div_q;
    out.ctrl.is_illegal = is_illegal_q;
    out.sel_eq          = sel_eq_q;
    out.sel_ne          = sel_ne_q;
    out.sel_lt          = sel_lt_q;
    out.sel_ge          = sel_ge_q;
    out.sel_ltu         = sel_ltu_q;
    out.sel_geu         = sel_geu_q;
    out.pred            = pred_q;
  end

endmodule
