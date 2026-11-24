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
  input  operand_sel_t      rs1_sel,
  input  operand_sel_t      rs2_sel,
  input  logic              load_compare,
  input  logic              load_address,
  input  logic              load_rs1,
  input  logic              load_rs2,
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

  // Only branches and JAL use this displacement. Opcode bit 3 selects
  // their layout without waiting for the full decode.
  logic [20:1] direct_offset;
  assign direct_offset = in.instr[3]
                       ? {in.instr[31], in.instr[19:12], in.instr[20], in.instr[30:21]}
                       : {{9{in.instr[31]}}, in.instr[7], in.instr[30:25], in.instr[11:8]};

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

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_data;
      reg_q.rs1_sel  <= rs1_sel;
      reg_q.rs2_sel  <= rs2_sel;
      reg_q.alu_a_sel  <= dec_is_auipc ? OPERAND_FALLBACK : rs1_sel;
      reg_q.alu_b_sel  <= dec_alu_src  ? OPERAND_FALLBACK : rs2_sel;
      reg_q.alu_a_base <= dec_is_auipc ? in.pc : rs1_data;
      reg_q.alu_b_base <= dec_alu_src  ? imm   : rs2_data;
      reg_q.addr_offset <= imm[11:0];
      reg_q.load_compare <= load_compare;
      reg_q.load_address <= load_address;
      reg_q.load_rs1     <= load_rs1;
      reg_q.load_rs2     <= load_rs2;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
      // A squash invalidates the captured operands and prediction together.
      reg_q.direct_offset    <= direct_offset;
      reg_q.predicted_taken  <= in.predicted_taken;
      reg_q.last_mapped_word <= in.last_mapped_word;
      reg_q.direction_index  <= in.pc[7:2] ^ in.pc[13:8];
      reg_q.valid    <= in.valid && !flush;
    end
  end

  assign out = reg_q;

endmodule
