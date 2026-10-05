// rtl/id_stage.sv
//
// Decode registers PC, controls, immediate and actual source addresses.
// RF values are reread by OF until its instruction really transfers.
//
// Latency:        1 cycle (ID/OF register clocked here).
// RVFI fields:    feeds rs1_addr, rs2_addr, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,
  input  if_id_t  in,
  output id_of_t  out
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

  logic use_rs1, use_rs2;
  assign use_rs1 = !dec_is_illegal &&
    (in.instr[6:0] == 7'h33 || in.instr[6:0] == 7'h13 ||
     dec_mem_read || dec_mem_write || dec_is_branch || dec_is_jalr);
  assign use_rs2 = !dec_is_illegal &&
    (in.instr[6:0] == 7'h33 || dec_mem_write || dec_is_branch);

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

  // ── ID/OF register ──────────────────────────────────────────────────────
  id_of_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      // A kill affects only validity. Wide payload holds under backend
      // backpressure or an operand load-use bubble.
      if (flush) reg_q.valid <= 1'b0;
      else if (!stall) reg_q.valid <= in.valid;
      if (flush) reg_q.predicted_taken <= 1'b0;
      else if (!stall) reg_q.predicted_taken <= in.valid && in.predicted_taken;
      if (!stall) begin
        reg_q.pc       <= in.pc;
        reg_q.imm      <= imm;
        reg_q.rd       <= in.instr[11:7];
        reg_q.rs1_addr <= in.instr[19:15];
        reg_q.rs2_addr <= in.instr[24:20];
        reg_q.use_rs1  <= use_rs1;
        reg_q.use_rs2  <= use_rs2;
        reg_q.ctrl     <= ctrl_decoded;
        reg_q.instr    <= in.instr;
      end
    end
  end

  assign out = reg_q;

endmodule
