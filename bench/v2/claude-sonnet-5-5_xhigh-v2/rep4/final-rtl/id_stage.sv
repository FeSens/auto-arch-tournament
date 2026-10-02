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
  // regfile read data (read addresses are driven from if_stage's unmasked
  // head fields at top level, off the redirect cone)
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Bypass network (selects from forward_unit): P1 = result of the
  // instruction in EX, P2 = result of the instruction in MEM (P1 has
  // priority; p2 hits are NOT qualified by !p1). Neither hit = regfile read
  // (the regfile is written from MEM, so it already holds the result of the
  // instruction in WB).
  input  logic [31:0]       ex_res,
  input  logic [31:0]       mem_res,
  input  logic              p1_hit_rs1,
  input  logic              p2_hit_rs1,
  input  logic              p1_hit_rs2,
  input  logic              p2_hit_rs2,
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
  logic        dec_late_res;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;
  logic        dec_is_illegal;
  logic        dec_mul_sgn_a;
  logic        dec_mul_sgn_b;
  logic        dec_mul_lo;
  logic        dec_mul_hi;

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
    .late_res   (dec_late_res),
    .mem_write  (dec_mem_write),
    .mem_width  (dec_mem_width),
    .mem_sext   (dec_mem_sext),
    .reg_write  (dec_reg_write),
    .mem_to_reg (dec_mem_to_reg),
    .is_illegal (dec_is_illegal),
    .mul_sgn_a  (dec_mul_sgn_a),
    .mul_sgn_b  (dec_mul_sgn_b),
    .mul_lo     (dec_mul_lo),
    .mul_hi     (dec_mul_hi)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  logic  rd_nz;
  ctrl_t ctrl_decoded;
  always_comb begin
    rd_nz = (in.instr[11:7] != 5'b0);
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.is_jump    = dec_is_jump;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.is_auipc   = dec_is_auipc;
    ctrl_decoded.mem_read   = dec_mem_read;
    // rd != 0 is folded into reg_write / late_res here, once, so the
    // downstream bypass enables (ex_res_en / mem_res_en), the regfile write
    // enable and the load-use check need no `rd != 0` compare. (RVFI is
    // unchanged: rd_wen was already forced to 0 for x0.)
    ctrl_decoded.late_res   = dec_late_res && rd_nz;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write && rd_nz;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_illegal = dec_is_illegal;
    ctrl_decoded.mul_sgn_a  = dec_mul_sgn_a;
    ctrl_decoded.mul_sgn_b  = dec_mul_sgn_b;
    ctrl_decoded.mul_lo     = dec_mul_lo;
    ctrl_decoded.mul_hi     = dec_mul_hi;
  end

  // ── Pre-muxed ALU B operand ─────────────────────────────────────────────
  // alu_b = alu_src ? imm : bypassed rs2, as one flat AND-OR over the
  // one-hot legs (P1 / P2 / regfile hits are qualified by !alu_src; the P2 leg
  // also excludes P1, since forward_unit's p2 hits are not mutually exclusive
  // with p1), so EX's ALU reads it straight from a flop with no alu_src mux in
  // front of the carry chain. ex_res stays in the last LUT level. rs2_val
  // keeps the plain priority-bypassed value (stores, branch compare, EX/MEM
  // write_data, RVFI).
  logic        b_sel_ex;
  logic        b_sel_mem;
  logic        b_sel_rf;
  logic [31:0] alu_b_d;
  always_comb begin
    b_sel_ex  = !dec_alu_src && p1_hit_rs2;
    b_sel_mem = !dec_alu_src && !p1_hit_rs2 && p2_hit_rs2;
    b_sel_rf  = !dec_alu_src && !p1_hit_rs2 && !p2_hit_rs2;
    alu_b_d   = ({32{b_sel_ex}}      & ex_res)
              | ({32{b_sel_mem}}     & mem_res)
              | ({32{b_sel_rf}}      & rs2_data)
              | ({32{dec_alu_src}}   & imm);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= p1_hit_rs1 ? ex_res : p2_hit_rs1 ? mem_res : rs1_data;
      reg_q.rs2_val  <= p1_hit_rs2 ? ex_res : p2_hit_rs2 ? mem_res : rs2_data;
      reg_q.alu_b    <= alu_b_d;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
      reg_q.pred_taken <= in.pred_taken;
    end
  end

  assign out = reg_q;

endmodule
