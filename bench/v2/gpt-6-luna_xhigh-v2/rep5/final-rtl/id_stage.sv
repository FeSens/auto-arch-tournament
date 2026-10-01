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
  // The ID/EX producer advances into EX/MEM alongside this instruction.
  input  logic [4:0]        id_ex_rd,
  // The current MEM-stage result is captured directly into the operands.
  input  logic [4:0]        mem_rd,
  input  logic [31:0]       mem_bypass_data,
  input  logic              mem_bypass_eligible,
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

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  // An older producer currently in MEM is about to leave that stage as
  // this instruction enters ID/EX. Capture its final, trap-adjusted
  // writeback value now so EX does not need a MEM/WB data mux.
  logic        rs1_mem_bypass;
  logic        rs2_mem_bypass;
  logic [31:0] rs1_capture_data;
  logic [31:0] rs2_capture_data;

  always_comb begin
    rs1_mem_bypass = mem_bypass_eligible && (mem_rd != 5'b0)
                   && (rs1_addr == mem_rd);
    rs2_mem_bypass = mem_bypass_eligible && (mem_rd != 5'b0)
                   && (rs2_addr == mem_rd);
    rs1_capture_data = rs1_mem_bypass ? mem_bypass_data : rs1_data;
    rs2_capture_data = rs2_mem_bypass ? mem_bypass_data : rs2_data;
  end

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

    // Invalid fetches keep their raw instruction bits in the pipeline,
    // but decode as side-effect-free bubbles. In particular, random or
    // wrong-path payloads cannot redirect EX, access memory, write a
    // register, or retire as an illegal instruction.
    if (!in.valid) begin
      ctrl_decoded = '0;
    end
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.pred_taken  <= in.pred_taken;
      reg_q.pred_target <= in.pred_target;
      reg_q.rs1_val  <= rs1_capture_data;
      reg_q.rs2_val  <= rs2_capture_data;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.rs1_ex_mem_match <= (in.instr[19:15] == id_ex_rd);
      reg_q.rs2_ex_mem_match <= (in.instr[24:20] == id_ex_rd);
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
