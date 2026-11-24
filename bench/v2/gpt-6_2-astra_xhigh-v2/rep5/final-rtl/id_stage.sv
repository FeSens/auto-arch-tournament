// rtl/id_stage.sv
//
// Decode the IF/ID instruction and capture its operands at the ID/EX
// boundary. The write-first ports include the completing MEM write.
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

  // The control and valid bits below kill all side effects on a bubble.
  // Recovery therefore does not enter the wide payload flops' enables.
  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.rs1_val <= rs1_data;
      reg_q.rs2_val <= rs2_data;
      reg_q.pc       <= in.pc;
      reg_q.pc_plus4 <= in.pc_plus4;
      reg_q.direct_target <= in.direct_target;
      reg_q.alternate_pc <= in.alternate_pc;
      reg_q.counter <= in.counter;
      reg_q.predicted_taken <= in.predicted_taken;
      reg_q.imm      <= dec_is_jump ? in.pc_plus4 : imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.instr    <= in.instr;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.valid <= 1'b0;
      reg_q.ctrl  <= '0;
    end else if (!stall) begin
      reg_q.valid <= in.valid && !flush;
      reg_q.ctrl  <= (in.valid && !flush) ? ctrl_decoded : '0;
    end
  end

  assign out = reg_q;

endmodule
