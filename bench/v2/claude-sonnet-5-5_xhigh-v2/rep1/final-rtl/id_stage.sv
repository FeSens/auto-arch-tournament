// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
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
  // Bypass-at-the-operand-register inputs. This instruction (I) captures its
  // operands at the end of the cycle in which I-1 is in EX (this module's own
  // ID/EX register) and I-2 is in MEM (EX/MEM); I-3 is in WB and is covered by
  // the regfile's write-first bypass.
  input  logic [31:0]       ex_result,          // I-1: EX result (late data)
  input  logic [31:0]       mem_load,           // I-2: raw dmem word (late data;
                                                // equals the load value for LW)
  input  logic [31:0]       mem_alu,            // I-2: EX/MEM.alu_result
  input  logic              mem_is_lw,          // I-2: EX/MEM.ctrl.mem_to_reg &&
                                                // mem_width == word
  input  logic [4:0]        ex_mem_rd,          // EX/MEM.rd (I-2)
  input  logic              ex_mem_rw,          // EX/MEM reg_write after the
                                                // MEM-stage misalign trap
  input  logic              jump_misal_ex,      // EX traps I-1 (clears its
                                                // reg_write in EX/MEM)
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
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // ── Bypass at the operand register ──────────────────────────────────────
  // The forwarded value is formed here, at ID/EX capture time, so EX has no
  // forward / operand-select muxes. Youngest producer wins:
  //   I-1 (ID/EX, now in EX)   : ex_result (late: ALU / pc+4 / muldiv)
  //   I-2 (EX/MEM, now in MEM) : the raw dmem word (late: BSRAM DO, no align)
  //                              for a LW, EX/MEM.alu_result otherwise
  //   I-3 and older            : regfile (its write-first bypass covers WB)
  // Sub-word loads (LB/LBU/LH/LHU) in MEM are NOT bypassed. INVARIANT: for a
  // sub-word load in MEM whose rd matches this instruction's rs1/rs2, the
  // hazard unit's load_use_hazard (ex_mem_sub_ld term: same EX/MEM flops, same
  // rd compare, but ignoring the MEM-stage trap qualifier, so a superset of
  // hit?_mem && !mem_is_lw && mem_to_reg) asserts stall_id this cycle. The
  // wrong value that rs?_early would pick here (mem_alu = the address) is
  // therefore never captured: the ID/EX data fields HOLD (stall) while
  // flush_id bubbles valid/ctrl. The consumer is re-captured next cycle, when
  // the load sits in WB and the regfile's write-first bypass returns the
  // correct (aligned / extended) value from the MEM/WB flops. Any change to
  // hit?_mem / mem_is_lw must keep the hazard term a superset of it.
  // The hit terms are functions of IF/ID instruction bits and ID/EX / EX/MEM
  // flops only, so the late data inputs (ex_result, mem_load) sit one 3:1
  // mux (LUT + MUX2_LUT5) from the ID/EX flop (for mem_load that is straight
  // from the BSRAM DO). ID/EX captures only on cycles
  // where EX and MEM also advance (dmem / muldiv stalls hold the whole pipe),
  // and a held ID/EX already contains its final operands.
  // x0 never matches (rd != 0 qualification). A misaligned-target jump in EX
  // clears I-1's reg_write in EX/MEM, so it must not forward and falls
  // through to I-2. Branches never write rd, so the late branch-taken term of
  // the full misalign fault is not needed here.
  logic idex_wr;
  logic exmem_wr;
  logic hit1_ex;
  logic hit1_mem;
  logic hit2_ex;
  logic hit2_mem;

  always_comb begin
    idex_wr  = reg_q.ctrl.reg_write && (reg_q.rd != 5'b0) && !jump_misal_ex;
    exmem_wr = ex_mem_rw            && (ex_mem_rd != 5'b0);

    hit1_ex  = idex_wr  && (reg_q.rd == rs1_addr);
    hit1_mem = exmem_wr && (ex_mem_rd == rs1_addr);
    hit2_ex  = idex_wr  && (reg_q.rd == rs2_addr);
    hit2_mem = exmem_wr && (ex_mem_rd == rs2_addr);
  end

  // Per operand: sel_ex / sel_ld pick the late data (mutually exclusive),
  // otherwise the early value (override / EX/MEM ALU result / regfile).
  logic [31:0] rs1_fwd;
  logic [31:0] rs2_fwd;
  logic [31:0] a_d;
  logic [31:0] b_d;
  logic [31:0] rs1_early;
  logic [31:0] rs2_early;
  logic [31:0] a_early;
  logic [31:0] b_early;
  logic        rs1_sel_ex;
  logic        rs1_sel_ld;
  logic        rs2_sel_ex;
  logic        rs2_sel_ld;
  logic        a_sel_ex;
  logic        a_sel_ld;
  logic        b_sel_ex;
  logic        b_sel_ld;

  always_comb begin
    rs1_early  = hit1_mem ? mem_alu : rs1_data;
    rs2_early  = hit2_mem ? mem_alu : rs2_data;
    rs1_sel_ex = hit1_ex;
    rs1_sel_ld = hit1_mem && mem_is_lw && !hit1_ex;
    rs2_sel_ex = hit2_ex;
    rs2_sel_ld = hit2_mem && mem_is_lw && !hit2_ex;

    rs1_fwd = rs1_sel_ex ? ex_result : (rs1_sel_ld ? mem_load : rs1_early);
    rs2_fwd = rs2_sel_ex ? ex_result : (rs2_sel_ld ? mem_load : rs2_early);

    // ALU operand a: pc for AUIPC, else the forwarded rs1.
    a_early  = dec_is_auipc ? in.pc : rs1_early;
    a_sel_ex = rs1_sel_ex && !dec_is_auipc;
    a_sel_ld = rs1_sel_ld && !dec_is_auipc;
    a_d      = a_sel_ex ? ex_result : (a_sel_ld ? mem_load : a_early);

    // ALU operand b: imm when alu_src, else the forwarded rs2.
    b_early  = dec_alu_src ? imm : rs2_early;
    b_sel_ex = rs2_sel_ex && !dec_alu_src;
    b_sel_ld = rs2_sel_ld && !dec_alu_src;
    b_d      = b_sel_ex ? ex_result : (b_sel_ld ? mem_load : b_early);
  end

  // PC-relative branch / JAL target, formed here so EX has no pc+imm adder.
  // (JALR's rs1+imm sum is still formed in EX; this value is unused for it.)
  logic [31:0] tgt;
  assign tgt = in.pc + imm;

  // Reset clears the whole struct. A flush bubble only clears valid and
  // ctrl: every consumer of the data fields is qualified by valid / ctrl
  // (an invalid slot never retires), so the ~230 data flops stay plain
  // CE flops with no flush term in their D path. The flush fan-out is just
  // the ~25 valid+ctrl flops. While stalled the register holds (flush is
  // never asserted together with a dmem/md stall; on load-use the held
  // data of the bubble is don't-care).
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      if (flush) begin
        reg_q.valid <= 1'b0;
        reg_q.ctrl  <= '0;
      end else if (!stall) begin
        reg_q.ctrl  <= ctrl_decoded;
        reg_q.valid <= in.valid;
      end
      if (!stall) begin
        reg_q.pc        <= in.pc;
        reg_q.pc_plus4  <= in.pc_plus4;
        reg_q.tgt       <= tgt;
        reg_q.tgt_misal <= (tgt[1:0] != 2'b00);
        reg_q.rs1_val   <= rs1_fwd;
        reg_q.rs2_val   <= rs2_fwd;
        reg_q.a_val     <= a_d;
        reg_q.b_val     <= b_d;
        reg_q.rd        <= in.instr[11:7];
        reg_q.rs1_addr  <= in.instr[19:15];
        reg_q.rs2_addr  <= in.instr[24:20];
        reg_q.instr     <= in.instr;
      end
    end
  end

  assign out = reg_q;

endmodule
