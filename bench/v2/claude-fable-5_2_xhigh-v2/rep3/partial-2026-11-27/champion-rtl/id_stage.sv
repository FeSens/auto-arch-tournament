// rtl/id_stage.sv
//
// Decode stage + operand bypass network. Owns the ID/EX register.
//
// Bypass-at-decode: rs1/rs2 are fully resolved at the ID/EX register
// INPUT, so ID/EX.rs1_val / rs2_val are always the final architectural
// operand values and the EX stage starts from flops (no forwarding muxes
// in EX). Sources, youngest writer first:
//   EX  leg : the instruction in ID/EX (its result this cycle, ex_result)
//   MEM leg : the instruction in EX/MEM (load data or ALU result; the two
//             arrive as separate legs, see the bypass network below)
//   WB  leg : the regfile's write-first bypass (inside reg_file)
//   else    : regfile read
// All selects are functions of registers + the raw fetched word; the
// late ex_result is the LAST 2:1 mux in front of the ID/EX D pins.
//
// This is exact because ID/EX only captures on a cycle where the EX and
// MEM instructions also advance (hold covers dmem stall and a running
// divide), and a LOAD in EX makes the consumer wait (load-use bubble),
// after which it takes the MEM leg.
//
// Final ALU operands (ID/EX.op_a / op_b) are selected HERE as well, so
// EX has no operand mux in front of its adder / shifter and no link mux
// behind the ALU:
//   op_a = pc   for AUIPC / JAL / JALR,           else rs1 (bypassed)
//   op_b = 4    for JAL / JALR (link = pc + 4, alu_op = ADD),
//          rs2 (bypassed) for R-type OP,          else imm
// The replacement values (pc, 4, imm) sit in the early leg; the bypass
// selects are gated off when the register operand is replaced, so the
// late ex_result still passes exactly ONE 2:1 mux, and the MEM leg is
// no deeper than for rs1_val / rs2_val.
// The operand class is taken from raw opcode bits (see below): exact for
// every legal instruction that uses the ALU result, don't-care otherwise.
// ID/EX.rs1_val / rs2_val are unchanged (branch compare, JALR target,
// AGU, store data, multiplier, divider, RVFI).
//
// The fetched word is decoded RAW. Kills (imem stall, load-use) arrive
// as `bubble`, a synchronous clear of ctrl/valid/rd only: the wide data
// fields of a bubble are don't-care and are not cleared.
//
// Zero-bubble redirect: there is no wrong-path kill any more. In a
// redirect cycle the fetch address IS the redirect target (if_stage), so
// in.pc / in.instr are the target instruction and it is captured like
// any other word. in.pc = redirect ? redirect_target : seq_addr is
// therefore late; it feeds ID/EX.pc through that single 2:1 mux. The
// op_a "pc" leg (AUIPC / JAL / JALR) takes `opa_pc`:
//   PC_LEG_LATE = 1 : opa_pc = in.pc (late). The pc leg is its own
//                     AND-OR term, OR-ed with the bypass legs (whose
//                     selects and early leg are gated off by a_pc), so
//                     the late redirect select is not chained through
//                     the bypass muxes.
//   PC_LEG_LATE = 0 : opa_pc = the sequential fetch address (flops
//                     only); the pc leg sits in the early operand as
//                     before. Requires the hazard unit to bubble a
//                     redirect-cycle word that needs pc as ALU operand.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage #(
  parameter bit PC_LEG_LATE = 1'b1
) (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,       // ID/EX keeps its contents
  input  logic              bubble,     // ID/EX ctrl/valid/rd <- 0 (wins over hold)
  input  if_id_t  in,
  input  logic [31:0]       opa_pc,     // pc value for the op_a pc leg
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // EX bypass leg (instruction currently in ID/EX)
  input  logic              ex_byp_en,
  input  logic [31:0]       ex_byp_data,
  // MEM bypass leg (instruction currently in EX/MEM)
  input  logic              mem_byp_en,
  input  logic [4:0]        mem_byp_rd,
  input  logic              mem_byp_load,       // MEM instr is a LOAD
  input  logic [31:0]       mem_byp_load_data,  // late:  aligned load data
  input  logic [31:0]       mem_byp_alu_data,   // early: EX/MEM.alu_result
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

  // Regfile read addresses come straight from the raw fetched word — these
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
  // Kept as plain per-field registers (not one struct written from two
  // always_ff blocks): the control fields have a synchronous clear, the
  // data fields do not.
  ctrl_t       ctrl_q;
  logic [4:0]  rd_q;
  logic        valid_q;
  logic [31:0] pc_q;
  logic [31:0] rs1_val_q;
  logic [31:0] rs2_val_q;
  logic [31:0] op_a_q;
  logic [31:0] op_b_q;
  logic [31:0] imm_q;
  logic [4:0]  rs1_addr_q;
  logic [4:0]  rs2_addr_q;
  logic [31:0] instr_q;

  // ── Operand bypass network ──────────────────────────────────────────────
  // The EX leg's rd is this module's own ID/EX.rd; ex_byp_en already
  // folds in reg_write, rd != 0 and "not trapping" (ex_stage). mem_byp_en
  // folds in reg_write, rd != 0 and "not a misaligned load" (mem_stage).
  //
  // The MEM leg is split in two by arrival time: a non-load MEM value is
  // EX/MEM.alu_result (flops) and is folded into the EARLY operand
  // together with the regfile read; only real load data (dmem read +
  // align, the other late signal) gets its own 2:1 select next to the EX
  // one. Both late signals are thus one small mux from the ID/EX D pins.
  logic        sel_ex_rs1,  sel_ex_rs2;
  logic        sel_mem_rs1, sel_mem_rs2;
  logic        sel_ld_rs1,  sel_ld_rs2;    // MEM leg, load data
  logic        sel_al_rs1,  sel_al_rs2;    // MEM leg, EX/MEM.alu_result
  logic [31:0] rs1_pre,     rs2_pre;
  logic [31:0] rs1_val_d,   rs2_val_d;

  always_comb begin
    sel_ex_rs1  = ex_byp_en  && (rd_q       == rs1_addr);
    sel_ex_rs2  = ex_byp_en  && (rd_q       == rs2_addr);
    sel_mem_rs1 = mem_byp_en && (mem_byp_rd == rs1_addr);
    sel_mem_rs2 = mem_byp_en && (mem_byp_rd == rs2_addr);
    sel_ld_rs1  = sel_mem_rs1 &&  mem_byp_load;
    sel_ld_rs2  = sel_mem_rs2 &&  mem_byp_load;
    sel_al_rs1  = sel_mem_rs1 && !mem_byp_load;
    sel_al_rs2  = sel_mem_rs2 && !mem_byp_load;

    // Early part: non-load MEM leg over regfile (which contains the WB
    // leg). Flops and LUT-RAM only.
    rs1_pre = sel_al_rs1 ? mem_byp_alu_data : rs1_data;
    rs2_pre = sel_al_rs2 ? mem_byp_alu_data : rs2_data;

    // Late part: load data, then one 2:1 mux for the EX result.
    rs1_val_d = sel_ex_rs1 ? ex_byp_data
                           : (sel_ld_rs1 ? mem_byp_load_data : rs1_pre);
    rs2_val_d = sel_ex_rs2 ? ex_byp_data
                           : (sel_ld_rs2 ? mem_byp_load_data : rs2_pre);
  end

  // ── Final ALU operands (op_a / op_b) ────────────────────────────────────
  // Operand class from raw opcode bits. Legal opcodes, instr[6:2]:
  //   LOAD 00000  FENCE 00011  OP-IMM 00100  AUIPC 00101  STORE 01000
  //   OP   01100  LUI   01101  BRANCH 11000  JALR  11001  JAL   11011
  //   SYSTEM 11100
  // The ALU result is architecturally used only by OP, OP-IMM, LUI,
  // AUIPC, JAL and JALR (LOAD/STORE address comes from the AGU; BRANCH /
  // FENCE / EBREAK / illegal words write nothing), so the selects only
  // have to be right for those six:
  //   op_a = pc   : AUIPC, JAL, JALR            <=> instr[2]
  //                 (also LUI, whose ALU arm ignores a)
  //   op_a = rs1  : OP, OP-IMM                  <=> !instr[2]
  //   op_b = 4    : JAL, JALR                   <=> instr[6]
  //   op_b = rs2  : OP                          <=> instr[6:5]==01 && !instr[2]
  //   op_b = imm  : OP-IMM, LUI, AUIPC          <=> otherwise
  logic        a_pc;
  logic        b_four;
  logic        b_reg;
  logic        sel_ex_a,  sel_ex_b;
  logic        sel_ld_a,  sel_ld_b;
  logic [31:0] op_a_pre,  op_b_pre;
  logic [31:0] op_a_d,    op_b_d;

  always_comb begin
    a_pc   = in.instr[2];
    b_four = in.instr[6];
    b_reg  = !in.instr[6] && in.instr[5] && !in.instr[2];

    // Late bypass selects, gated off when the register operand is
    // replaced.
    sel_ex_a = sel_ex_rs1 && !a_pc;
    sel_ld_a = sel_ld_rs1 && !a_pc;
    sel_ex_b = sel_ex_rs2 && b_reg;
    sel_ld_b = sel_ld_rs2 && b_reg;

    // Early leg: replacement value, or the early register operand
    // (regfile / WB leg / non-load MEM leg).
    if (PC_LEG_LATE) op_a_pre = a_pc ? 32'b0  : rs1_pre;
    else             op_a_pre = a_pc ? opa_pc : rs1_pre;
    op_b_pre = b_reg ? rs2_pre : (b_four ? 32'd4 : imm);

    // Load data, then the single late 2:1 mux for the EX result.
    op_a_d = sel_ex_a ? ex_byp_data
                      : (sel_ld_a ? mem_byp_load_data : op_a_pre);
    // Late pc leg (redirect-muxed fetch pc) as a separate AND-OR term:
    // with a_pc set, sel_ex_a = sel_ld_a = 0 and op_a_pre = 0.
    if (PC_LEG_LATE) op_a_d = op_a_d | ({32{a_pc}} & opa_pc);
    op_b_d = sel_ex_b ? ex_byp_data
                      : (sel_ld_b ? mem_byp_load_data : op_b_pre);
  end

  // Control fields: bubble (sync clear) wins over hold.
  always_ff @(posedge clock) begin
    if (reset || bubble) begin
      ctrl_q  <= '0;
      rd_q    <= 5'b0;
      valid_q <= 1'b0;
    end else if (!hold) begin
      ctrl_q  <= ctrl_decoded;
      rd_q    <= in.instr[11:7];
      valid_q <= in.valid;
    end
  end

  // Data fields: don't-care in a bubble, so only the hold matters.
  always_ff @(posedge clock) begin
    if (reset) begin
      pc_q       <= 32'b0;
      rs1_val_q  <= 32'b0;
      rs2_val_q  <= 32'b0;
      op_a_q     <= 32'b0;
      op_b_q     <= 32'b0;
      imm_q      <= 32'b0;
      rs1_addr_q <= 5'b0;
      rs2_addr_q <= 5'b0;
      instr_q    <= 32'b0;
    end else if (!hold) begin
      pc_q       <= in.pc;
      rs1_val_q  <= rs1_val_d;
      rs2_val_q  <= rs2_val_d;
      op_a_q     <= op_a_d;
      op_b_q     <= op_b_d;
      imm_q      <= imm;
      rs1_addr_q <= in.instr[19:15];
      rs2_addr_q <= in.instr[24:20];
      instr_q    <= in.instr;
    end
  end

  always_comb begin
    out.pc       = pc_q;
    out.rs1_val  = rs1_val_q;
    out.rs2_val  = rs2_val_q;
    out.op_a     = op_a_q;
    out.op_b     = op_b_q;
    out.imm      = imm_q;
    out.rd       = rd_q;
    out.rs1_addr = rs1_addr_q;
    out.rs2_addr = rs2_addr_q;
    out.ctrl     = ctrl_q;
    out.instr    = instr_q;
    out.valid    = valid_q;
  end

endmodule
