// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID REGISTER (if_stage) plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Besides the plain decode, ID prepares everything EX would otherwise
// have to mux late:
//   - op_a / op_b : ALU operands pre-muxed (pc / 0 / rs1, imm / rs2) with
//     their own forward-match bits (cleared when not a register read);
//   - btarget     : the next pc fetch did NOT follow (pc + imm from the
//     fetch-cycle adders, or pc + 4 when the branch was predicted taken);
//     redir_c1 / redir_c0 carry the prediction, so EX redirects exactly
//     on a mispredict;
//   - link        : pc + 4 for JAL/JALR, else 0;
//   - jal_ok / br_ok / br_bad : the PC is always 4-aligned, so the target
//     of a JAL / branch is misaligned iff imm[1]. A misaligned JAL traps
//     right here (is_illegal=1, reg_write=0, no redirect).
//
// ID/EX register groups:
//   control (valid + side-effect bits): cleared on reset / kill.
//   data    (everything else)         : clock-enable = !hold, never cleared.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,   // ID/EX keeps its instruction
  input  logic              kill,   // bubble into ID/EX (ignored while hold)
  // Registered IF/ID bundle. in.valid is consumed by hazard_unit (kill).
  /* verilator lint_off UNUSEDSIGNAL */
  input  if_id_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // rd of the instruction currently in EX/MEM (forward-match precompute)
  input  logic [4:0]        ex_mem_rd,
  // MEM -> ID capture bypass sources: the instruction in EX/MEM moves to
  // MEM/WB at the same edge ID/EX captures, so its rd value is
  //   ex_mem_to_reg ? mem_load_data : ex_mem_alu
  input  logic [31:0]       ex_mem_alu,     // EX/MEM.alu_result (flop)
  input  logic              ex_mem_to_reg,  // EX/MEM.ctrl.mem_to_reg (flop)
  input  logic [31:0]       mem_load_data,  // late: dmem read data, extracted
  // reg_write bits as they will be registered at the next clock edge:
  //   ex_reg_write_next  : of the instruction in EX  (-> EX/MEM)
  //   mem_reg_write_next : of the instruction in MEM (-> MEM/WB)
  input  logic              ex_reg_write_next,
  input  logic              mem_reg_write_next,
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0]  dec_alu_op;       // EX uses the one-hot selects instead
  logic [2:0]  dec_branch_op;    // == instr[14:12]
  // The op_a / op_b pre-mux uses raw opcode bits instead (see below).
  logic        dec_alu_src;
  logic        dec_is_lui;
  logic        dec_is_auipc;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        dec_is_branch;
  logic        dec_is_jump;
  logic        dec_is_jalr;
  logic        dec_mem_read;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;
  logic        dec_is_illegal;
  logic        dec_is_muldiv;
  logic        dec_sel_add;
  logic        dec_alu_sub;
  logic        dec_sel_slt;
  logic        dec_slt_signed;
  logic [1:0]  dec_logic_op;
  logic        dec_sel_shl;
  logic        dec_sel_shr;
  logic        dec_sh_arith;

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
    .is_illegal (dec_is_illegal),
    .is_muldiv  (dec_is_muldiv),
    .sel_add    (dec_sel_add),
    .alu_sub    (dec_alu_sub),
    .sel_slt    (dec_sel_slt),
    .slt_signed (dec_slt_signed),
    .logic_op   (dec_logic_op),
    .sel_shl    (dec_sel_shl),
    .sel_shr    (dec_sel_shr),
    .sh_arith   (dec_sh_arith)
  );

  // ── ID/EX register (declared early: used by the match precompute) ──────
  id_ex_t reg_q;

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  // ── Decode-time redirect / trap terms ───────────────────────────────────
  // pc[1:0] == 0 always and imm[0] == 0 for B/J immediates, so the
  // target pc + imm is misaligned iff imm[1].
  logic is_jal;
  logic jal_bad;
  always_comb begin
    is_jal  = dec_is_jump && !dec_is_jalr;
    jal_bad = is_jal && imm[1];
  end

  // ── Forwarding match precompute ─────────────────────────────────────────
  // Whenever ID/EX captures a new instruction (no hold, no kill) the
  // pipeline moves in lock-step: the instruction now in ID/EX moves to
  // EX/MEM and the one in EX/MEM moves to MEM/WB. So a match against
  // ID/EX.rd now is a match against EX/MEM.rd when this instruction
  // executes, and a match against EX/MEM.rd now is a match against
  // MEM/WB.rd then. The reg_write qualifiers are applied late, in EX
  // (they carry trap gating) — which is also what makes the stale rd of
  // a bubble harmless (rd is a data field, not cleared on a bubble).
  //
  // The reg_write qualifier is folded in here too: when ID/EX captures,
  // EX/MEM captures the EX instruction with `ex_reg_write_next` and MEM/WB
  // captures the MEM instruction with `mem_reg_write_next` at the same
  // edge. The *_mem match is consumed right here (capture bypass: the
  // MEM instruction's value is written into the ID/EX operand registers,
  // which hold it for as long as the consumer sits in EX). While the
  // consumer sits in EX for more than one cycle the *_ex select stays
  // exact:
  //   dmem stall : EX/MEM holds;
  //   M-op busy  : the sources drain, but the muldiv unit latched its
  //                operands on the first EX cycle and nothing else of an
  //                M-op uses rs1/rs2.
  logic m_rs1_ex, m_rs1_mem, m_rs2_ex, m_rs2_mem;
  always_comb begin
    m_rs1_ex  = (reg_q.rd   != 5'b0) && (reg_q.rd   == in.instr[19:15])
                && ex_reg_write_next;
    m_rs2_ex  = (reg_q.rd   != 5'b0) && (reg_q.rd   == in.instr[24:20])
                && ex_reg_write_next;
    m_rs1_mem = (ex_mem_rd  != 5'b0) && (ex_mem_rd  == in.instr[19:15])
                && mem_reg_write_next;
    m_rs2_mem = (ex_mem_rd  != 5'b0) && (ex_mem_rd  == in.instr[24:20])
                && mem_reg_write_next;
  end

  // ── MEM -> ID capture bypass + ALU operand pre-mux ──────────────────────
  // D = sel_ld ? load_data : early. Everything in `early` is a flop, the
  // regfile read or the pc / 0 / imm pre-mux; the late load data enters
  // on the last 2:1 only.
  //
  // op_a / op_b are consumed ONLY by instructions whose rd is an RV32I ALU
  // value (every ALU result select is 0 otherwise and the ALU returns
  // `other`): OP 01100, OP-IMM 00100, LUI 01101, AUIPC 00101 (instr[6:2]).
  // Among those, two raw opcode bits pick the operand class, so the
  // pre-mux selects do not wait for the validated decode:
  //   instr[2]              : a is not a register (LUI / AUIPC)
  //   instr[2] & !instr[5]  : a = pc  (AUIPC);  instr[2] & instr[5] : a = 0
  //   instr[5] & !instr[2]  : b = rs2 (OP), else imm
  // For every other opcode op_a / op_b (and fwd_a_ex / fwd_b_ex) are
  // don't-care.
  logic        a_is_reg;
  logic        a_pc;
  logic        a_zero;
  logic        b_is_reg;
  logic        sel_ld1, sel_ld2;     // producer in MEM is a LOAD
  logic        sel_al1, sel_al2;     // producer in MEM has an ALU value
  // syn_keep: pin the "late load data on the last 2:1 only" structure (the
  // tool otherwise builds op_a from rs1_byp, one LUT deeper for dmem data).
  // None of these nets is fed by a carry chain.
  logic [31:0] rs1_early /* synthesis syn_keep = 1 */;
  logic [31:0] rs2_early /* synthesis syn_keep = 1 */;
  logic [31:0] opa_early /* synthesis syn_keep = 1 */;
  logic [31:0] opb_early /* synthesis syn_keep = 1 */;
  logic [31:0] rs1_byp, rs2_byp;
  logic [31:0] op_a;
  logic [31:0] op_b;
  always_comb begin
    a_is_reg  = !in.instr[2];
    a_pc      =  in.instr[2] && !in.instr[5];
    a_zero    =  in.instr[2] &&  in.instr[5];
    b_is_reg  =  in.instr[5] && !in.instr[2];
    sel_ld1   = m_rs1_mem &&  ex_mem_to_reg;
    sel_ld2   = m_rs2_mem &&  ex_mem_to_reg;
    sel_al1   = m_rs1_mem && !ex_mem_to_reg;
    sel_al2   = m_rs2_mem && !ex_mem_to_reg;

    rs1_early = sel_al1 ? ex_mem_alu : rs1_data;
    rs2_early = sel_al2 ? ex_mem_alu : rs2_data;
    opa_early = a_pc     ? in.pc
              : a_zero   ? 32'b0
                         : rs1_early;
    opb_early = b_is_reg ? rs2_early : imm;

    rs1_byp   = sel_ld1 ? mem_load_data : rs1_early;
    rs2_byp   = sel_ld2 ? mem_load_data : rs2_early;
    op_a      = (sel_ld1 && a_is_reg)     ? mem_load_data : opa_early;
    op_b      = (sel_ld2 && b_is_reg)     ? mem_load_data : opb_early;
  end

  always_ff @(posedge clock) begin
    // ── control group: valid + side-effect bits ──────────────────────────
    if (reset) begin
      reg_q.valid           <= 1'b0;
      reg_q.is_muldiv       <= 1'b0;
      reg_q.redir_c1        <= 1'b0;
      reg_q.redir_c0        <= 1'b0;
      reg_q.bp_train        <= 1'b0;
      reg_q.is_jalr         <= 1'b0;
      reg_q.br_bad          <= 1'b0;
      reg_q.ctrl.reg_write  <= 1'b0;
      reg_q.ctrl.mem_read   <= 1'b0;
      reg_q.ctrl.mem_write  <= 1'b0;
      reg_q.ctrl.is_illegal <= 1'b0;
    end else if (!hold) begin
      if (kill) begin
        reg_q.valid           <= 1'b0;
        reg_q.is_muldiv       <= 1'b0;
        reg_q.redir_c1        <= 1'b0;
        reg_q.redir_c0        <= 1'b0;
        reg_q.bp_train        <= 1'b0;
        reg_q.is_jalr         <= 1'b0;
        reg_q.br_bad          <= 1'b0;
        reg_q.ctrl.reg_write  <= 1'b0;
        reg_q.ctrl.mem_read   <= 1'b0;
        reg_q.ctrl.mem_write  <= 1'b0;
        reg_q.ctrl.is_illegal <= 1'b0;
      end else begin
        // Not killed => IF/ID holds a valid instruction and this is not
        // a flush cycle (kill covers !in.valid and flush_q).
        // Redirect = mispredict. An aligned JAL was already followed in
        // the fetch cycle; a branch redirects when the resolved direction
        // differs from in.pred_taken (taken = c ^ br_inv).
        reg_q.valid           <= 1'b1;
        reg_q.is_muldiv       <= dec_is_muldiv;
        // An aligned JAL that fetch did not follow (flush cycle) redirects
        // unconditionally: btarget = tgt, npc_pred = pc4 when !pred_taken.
        reg_q.redir_c1        <= (dec_is_branch && !imm[1] &&
                                  (in.instr[12] == in.pred_taken)) ||
                                 (is_jal && !imm[1] && !in.pred_taken);
        reg_q.redir_c0        <= (dec_is_branch && !imm[1] &&
                                  (in.instr[12] != in.pred_taken)) ||
                                 (is_jal && !imm[1] && !in.pred_taken);
        // PHT training only for aligned branches whose PHT entry was read
        // with the right index (not fetched in a flush cycle).
        reg_q.bp_train        <= dec_is_branch && !imm[1] && !in.fl;
        reg_q.is_jalr         <= dec_is_jalr;
        reg_q.br_bad          <= dec_is_branch && imm[1];
        reg_q.ctrl.reg_write  <= dec_reg_write && !jal_bad;
        reg_q.ctrl.mem_read   <= dec_mem_read;
        reg_q.ctrl.mem_write  <= dec_mem_write;
        reg_q.ctrl.is_illegal <= dec_is_illegal || jal_bad;
      end
    end

    // ── data group: clock-enable only, never cleared ─────────────────────
    if (!hold) begin
      reg_q.pc              <= in.pc;
      reg_q.rs1_val         <= rs1_byp;
      reg_q.rs2_val         <= rs2_byp;
      reg_q.imm             <= imm;
      reg_q.op_a            <= op_a;
      reg_q.op_b            <= op_b;
      reg_q.link            <= dec_is_jump ? in.pc4 : 32'b0;
      // Alternate path (the one fetch did not follow) for the redirect;
      // the followed path only feeds RVFI pc_wdata.
      reg_q.btarget         <= in.pred_taken ? in.pc4 : in.tgt;
      reg_q.npc_pred        <= in.pred_taken ? in.tgt : in.pc4;
      reg_q.pht             <= in.pht;
      reg_q.rd              <= in.instr[11:7];
      reg_q.rs1_addr        <= in.instr[19:15];
      reg_q.rs2_addr        <= in.instr[24:20];
      reg_q.fwd_rs1_ex      <= m_rs1_ex;
      reg_q.fwd_rs2_ex      <= m_rs2_ex;
      reg_q.fwd_a_ex        <= m_rs1_ex  && a_is_reg;
      reg_q.fwd_b_ex        <= m_rs2_ex  && b_is_reg;
      reg_q.sel_add         <= dec_sel_add;
      reg_q.alu_sub         <= dec_alu_sub;
      reg_q.sel_slt         <= dec_sel_slt;
      reg_q.slt_signed      <= dec_slt_signed;
      reg_q.logic_op        <= dec_logic_op;
      reg_q.sel_shl         <= dec_sel_shl;
      reg_q.sel_shr         <= dec_sel_shr;
      reg_q.sh_arith        <= dec_sh_arith;
      // BEQ 000 / BNE 001 / BLT 100 / BGE 101 / BLTU 110 / BGEU 111
      reg_q.br_use_eq       <= !in.instr[14];
      reg_q.br_signed       <= !in.instr[13];
      reg_q.br_inv          <= in.instr[12];
      reg_q.ctrl.mem_width  <= dec_mem_width;
      reg_q.ctrl.mem_sext   <= dec_mem_sext;
      reg_q.ctrl.mem_to_reg <= dec_mem_to_reg;
      reg_q.instr           <= in.instr;
    end
  end

  assign out = reg_q;

endmodule
