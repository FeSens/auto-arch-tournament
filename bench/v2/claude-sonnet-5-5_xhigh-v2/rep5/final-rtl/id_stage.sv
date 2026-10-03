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
  // Raw rs1/rs2 fields of the fetched word (imem_data[19:15] / [24:20]),
  // NOT the NOP-substituted in.instr: keeps the late EX redirect off the
  // regfile-read / load-use path. For an invalid slot (redirect / imem
  // stall) the regfile data is don't-care: that slot is captured as a
  // bubble (valid = 0 and, on redirect, ctrl cleared by flush).
  input  logic [31:0]       raw_instr,
  input  logic [4:0]        raw_rs1,
  input  logic [4:0]        raw_rs2,
  // rd of the instruction now in EX/MEM (= in MEM/WB when this word is in
  // EX); the instruction now in ID/EX is this stage's own reg_q.rd.
  input  logic [4:0]        ex_mem_rd,
  // Late bypass from MEM: the write-back value / enable the instruction now
  // in EX/MEM will have in MEM/WB (D inputs of the MEM/WB wb_data and
  // reg_write flops). Takes priority over the regfile read (it is younger
  // than the WB-stage write the regfile bypass sees).
  input  logic [31:0]       wb_fwd_data,
  input  logic              wb_fwd_en,
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
  assign rs1_addr = raw_rs1;
  assign rs2_addr = raw_rs2;

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

    // One-hot EX result select + shared adder / shifter sub-op controls.
    // A jump's result is the link value (pc+4), never the adder output.
    ctrl_decoded.sel_add    = (dec_alu_op == ALU_ADD || dec_alu_op == ALU_SUB)
                              && !dec_is_jump;
    ctrl_decoded.sel_and    = (dec_alu_op == ALU_AND);
    ctrl_decoded.sel_or     = (dec_alu_op == ALU_OR);
    ctrl_decoded.sel_xor    = (dec_alu_op == ALU_XOR);
    ctrl_decoded.sel_slt    = (dec_alu_op == ALU_SLT || dec_alu_op == ALU_SLTU);
    ctrl_decoded.sel_shift  = (dec_alu_op == ALU_SLL || dec_alu_op == ALU_SRL ||
                               dec_alu_op == ALU_SRA);
    ctrl_decoded.sel_lui    = (dec_alu_op == ALU_LUI);
    ctrl_decoded.sel_mdu    = (dec_alu_op >= ALU_MUL) && (dec_alu_op <= ALU_REMU);
    ctrl_decoded.sel_pc4    = dec_is_jump;
    ctrl_decoded.alu_sub    = (dec_alu_op == ALU_SUB || dec_alu_op == ALU_SLT ||
                               dec_alu_op == ALU_SLTU);
    ctrl_decoded.slt_u      = (dec_alu_op == ALU_SLTU);
    ctrl_decoded.sh_left    = (dec_alu_op == ALU_SLL);
    ctrl_decoded.sh_arith   = (dec_alu_op == ALU_SRA);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  // flush (a bubble) only has to kill `valid` and `ctrl`: with ctrl = '0 the
  // slot has no side effect (no reg_write / mem op / branch / jump / MDU op)
  // and valid = 0 keeps it out of RVFI, so the wide data fields are simply
  // not reset on flush. That keeps the late redirect -> flush_id net off the
  // ~190 data flops and shortens the critical redirect cone.
  id_ex_t reg_q;

  // Forward matches for the word being captured, from the raw rs1/rs2
  // fields (same source as the regfile read and the load-use compare):
  //   m1: the instruction in ID/EX now  -> in EX/MEM next cycle
  //       (registered; EX forwards its ALU result)
  //   m2: the instruction in EX/MEM now -> in MEM/WB next cycle
  //       (not registered; folded into rs?_val right here from the MEM-stage
  //       write-back value)
  // Pipeline advance is lock-step whenever ID/EX captures (stall_id covers
  // dmem_stall / load-use / ex_busy), so the instruction now in EX/MEM moves
  // to MEM/WB at this very edge and its write-back value is final. A stale
  // m1 match against a bubble is masked in EX by the registered reg_write.
  logic m1_rs1_d, m2_rs1_d, m1_rs2_d, m2_rs2_d;
  logic [31:0] rs1_val_d, rs2_val_d;
  always_comb begin
    m1_rs1_d = (raw_rs1 != 5'b0) && (raw_rs1 == reg_q.rd);
    m2_rs1_d = (raw_rs1 != 5'b0) && (raw_rs1 == ex_mem_rd);
    m1_rs2_d = (raw_rs2 != 5'b0) && (raw_rs2 == reg_q.rd);
    m2_rs2_d = (raw_rs2 != 5'b0) && (raw_rs2 == ex_mem_rd);

    rs1_val_d = (m2_rs1_d && wb_fwd_en) ? wb_fwd_data : rs1_data;
    rs2_val_d = (m2_rs2_d && wb_fwd_en) ? wb_fwd_data : rs2_data;
  end

  // ALU operand pre-selection. Decoded from the raw fetched word (not the
  // redirect-masked in.instr) so the late EX redirect stays off these ~66
  // flop inputs; a flushed / not-delivered slot is a bubble (valid = 0, no
  // side effects), so its operands are don't-care. For a valid slot raw ==
  // in.instr. alu_src / is_auipc are matched by opcode only: they differ
  // from the decoder's ctrl.alu_src only for illegal encodings (reg_write =
  // 0, no mem op, no jump / branch), whose ALU result is never used.
  logic        raw_is_auipc, raw_alu_src;
  logic [31:0] raw_imm;
  logic [31:0] alu_a_val_d, alu_b_val_d;
  logic        m1_alu_a_d, m1_alu_b_d;

  imm_gen u_imm_raw (.instr(raw_instr), .imm(raw_imm));

  always_comb begin
    raw_is_auipc = (raw_instr[6:0] == 7'b0010111);
    case (raw_instr[6:0])
      // LOAD, OP-IMM, STORE, JALR, LUI, AUIPC
      7'b0000011, 7'b0010011, 7'b0100011,
      7'b1100111, 7'b0110111, 7'b0010111: raw_alu_src = 1'b1;
      default:                            raw_alu_src = 1'b0;
    endcase

    alu_a_val_d = raw_is_auipc ? in.pc  : rs1_val_d;
    alu_b_val_d = raw_alu_src  ? raw_imm : rs2_val_d;
    m1_alu_a_d  = m1_rs1_d && !raw_is_auipc;
    m1_alu_b_d  = m1_rs2_d && !raw_alu_src;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.pc       <= '0;
      reg_q.rs1_val  <= '0;
      reg_q.rs2_val  <= '0;
      reg_q.imm      <= '0;
      reg_q.rd       <= '0;
      reg_q.rs1_addr <= '0;
      reg_q.rs2_addr <= '0;
      reg_q.instr    <= '0;
      reg_q.m1_rs1   <= 1'b0;
      reg_q.m1_rs2   <= 1'b0;
      reg_q.alu_a_val <= '0;
      reg_q.alu_b_val <= '0;
      reg_q.m1_alu_a <= 1'b0;
      reg_q.m1_alu_b <= 1'b0;
    end else if (!stall) begin
      reg_q.m1_rs1   <= m1_rs1_d;
      reg_q.m1_rs2   <= m1_rs2_d;
      reg_q.alu_a_val <= alu_a_val_d;
      reg_q.alu_b_val <= alu_b_val_d;
      reg_q.m1_alu_a <= m1_alu_a_d;
      reg_q.m1_alu_b <= m1_alu_b_d;
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_val_d;
      reg_q.rs2_val  <= rs2_val_d;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.instr    <= in.instr;
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q.ctrl       <= '0;
      reg_q.valid      <= 1'b0;
      reg_q.pred_taken <= 1'b0;
    end else if (!stall) begin
      reg_q.ctrl       <= ctrl_decoded;
      reg_q.valid      <= in.valid;
      reg_q.pred_taken <= in.pred_taken;
    end
  end

  assign out = reg_q;

endmodule
