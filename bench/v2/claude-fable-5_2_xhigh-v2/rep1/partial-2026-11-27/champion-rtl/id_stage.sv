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
  // forwarding selects for this instruction's next (EX) cycle, computed by
  // forward_unit from the instructions currently in EX and MEM
  input  logic [1:0]        fwd_rs1_sel,
  input  logic [1:0]        fwd_rs2_sel,
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
  logic        dec_is_mul;
  logic        dec_is_div;

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
    .is_mul     (dec_is_mul),
    .is_div     (dec_is_div)
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
    ctrl_decoded.is_mul     = dec_is_mul;
    ctrl_decoded.is_div     = dec_is_div;
  end

  // Low two bits of the branch / JAL target (pc + imm): alignment of the
  // target is decided here so EX's redirect needs no adder bits.
  logic [1:0] tgt_lo;
  logic       tgt_aligned;
  assign tgt_lo      = in.pc[1:0] + imm[1:0];
  assign tgt_aligned = (tgt_lo == 2'b00);

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_data;
      // ALU operands pre-muxed here so EX has a single 3:1 forward mux
      // (registered selects) in front of the adder.
      reg_q.op_a     <= dec_is_auipc ? in.pc : rs1_data;
      reg_q.op_b     <= dec_alu_src  ? imm   : rs2_data;
      reg_q.fwd_rs1  <= fwd_rs1_sel;
      reg_q.fwd_rs2  <= fwd_rs2_sel;
      reg_q.fwd_a    <= dec_is_auipc ? 2'd0 : fwd_rs1_sel;
      reg_q.fwd_b    <= dec_alu_src  ? 2'd0 : fwd_rs2_sel;
      reg_q.sel_add  <= (dec_alu_op == ALU_ADD || dec_alu_op == ALU_SUB)
                        && !dec_is_jump;
      reg_q.br_ok    <= dec_is_branch && tgt_aligned;
      reg_q.br_bad   <= dec_is_branch && !tgt_aligned;
      reg_q.jal_bad  <= dec_is_jump && !dec_is_jalr && !tgt_aligned;
      // Fetch only ever predicts a legal branch with an aligned target
      // (so pred_taken implies br_ok); the AND just makes that local.
      reg_q.pred_taken <= in.pred_taken && dec_is_branch && tgt_aligned;
      reg_q.pred_ctr   <= in.pred_ctr;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
