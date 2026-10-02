// rtl/id_stage.sv
//
// Separate decoded metadata and complete operand register banks.
// Fetch replaces a decoded record only when that record can transfer.
//
// Latency:        2 cycles (decoded and ID/EX flops clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              hold_ex,
  input  logic              squash,
  input  logic              flush,
  input  if_id_t  in,
  input  producer_tag_t     next_ex_tag,
  input  logic [1:0]        incoming_mem_match,
  input  logic              mem_hold,
  input  logic              ex_advance,
  output decoded_t          decoded,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  // Current EX and accepted MEM, selected using registered matches.
  input  logic [31:0]       resolved_rs1,
  input  logic [31:0]       resolved_rs2,
  input  logic [31:0]       complete_alu_a,
  input  logic [31:0]       complete_alu_b,
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

  decoded_t decoded_q;
  // Target addition and prediction equality start only from decoded flops.
  logic [31:0] direct_target;
  assign direct_target = decoded_q.pc + decoded_q.imm;

  // Only registered source addresses drive operand-read and the RF.
  assign rs1_addr = decoded_q.rs1_addr;
  assign rs2_addr = decoded_q.rs2_addr;

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

  // Match incoming source tags to actual next EX and MEM positions. Both
  // ages remain independent until late result/trap qualification.
  always_ff @(posedge clock) begin
    if (reset || squash) decoded_q <= '0;
    else if (!stall) begin
      if (!in.valid) decoded_q <= '0;
      else begin
        decoded_q.pc <= in.pc;
        decoded_q.instr <= in.instr;
        decoded_q.imm <= imm;
        decoded_q.prediction_selected <= in.prediction_selected;
        decoded_q.predicted_target <= in.predicted_target;
        decoded_q.rd <= in.instr[11:7];
        decoded_q.rs1_addr <= in.instr[19:15];
        decoded_q.rs2_addr <= in.instr[24:20];
        decoded_q.ctrl <= ctrl_decoded;
        decoded_q.valid <= 1'b1;
        decoded_q.provenance.rs1_ex <= next_ex_tag.writer && next_ex_tag.rd != 0 &&
                                    next_ex_tag.rd == in.instr[19:15];
        decoded_q.provenance.rs2_ex <= next_ex_tag.writer && next_ex_tag.rd != 0 &&
                                    next_ex_tag.rd == in.instr[24:20];
        decoded_q.provenance.rs1_mem <= incoming_mem_match[1];
        decoded_q.provenance.rs2_mem <= incoming_mem_match[0];
      end
    end else begin
      // No younger recapture during a hold. Rebase provenance as older
      // instructions drain; the write-first RF preserves departed writers.
      if (!mem_hold) begin
        decoded_q.provenance.rs1_mem <= ex_advance && decoded_q.provenance.rs1_ex;
        decoded_q.provenance.rs2_mem <= ex_advance && decoded_q.provenance.rs2_ex;
      end
      if (!hold_ex) begin
        decoded_q.provenance.rs1_ex <= 1'b0;
        decoded_q.provenance.rs2_ex <= 1'b0;
      end
    end
  end

  // EX consumes complete, stable flops, including during blocking work.
  id_ex_t reg_q;
  always_ff @(posedge clock) begin
    if (reset || flush) reg_q <= '0;
    else if (!hold_ex) begin
      if (!decoded_q.valid) reg_q <= '0;
      else begin
          reg_q.pc       <= decoded_q.pc;
          reg_q.prediction_selected <= decoded_q.prediction_selected;
          reg_q.predicted_target <= decoded_q.predicted_target;
          reg_q.direct_target <= direct_target;
          reg_q.direct_target_match <= direct_target == decoded_q.predicted_target;
          reg_q.rs1_val  <= resolved_rs1;
          reg_q.rs2_val  <= resolved_rs2;
          reg_q.alu_a_val <= complete_alu_a;
          reg_q.alu_b_val <= complete_alu_b;
          reg_q.imm      <= decoded_q.imm;
          reg_q.rd       <= decoded_q.rd;
          reg_q.rs1_addr <= decoded_q.rs1_addr;
          reg_q.rs2_addr <= decoded_q.rs2_addr;
          reg_q.ctrl     <= decoded_q.ctrl;
          reg_q.instr    <= decoded_q.instr;
          reg_q.valid    <= 1'b1;
      end
    end
  end

  assign out = reg_q;
  assign decoded = decoded_q;

endmodule
