// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the write-first regfile read data and advancing EX/completing MEM
// results. Architectural operands and final ALU inputs are registered
// together here. The ID/EX register is owned by this module so
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
  // 0 = write-first RF (including WB), 1 = advancing EX, 2 = completing MEM
  input  logic [1:0]        fwd_rs1_sel,
  input  logic [1:0]        fwd_rs2_sel,
  input  logic [31:0]       fwd_ex_data,
  input  logic [31:0]       fwd_mem_data,
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

  logic [31:0] rs1_value, rs2_value;
  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1_value = fwd_ex_data;
      2'd2:    rs1_value = fwd_mem_data;
      default: rs1_value = rs1_data;
    endcase
    case (fwd_rs2_sel)
      2'd1:    rs2_value = fwd_ex_data;
      2'd2:    rs2_value = fwd_mem_data;
      default: rs2_value = rs2_data;
    endcase
    // x0 is architectural zero even if a producer's controls are corrupt.
    if (rs1_addr == 5'b0) rs1_value = 32'b0;
    if (rs2_addr == 5'b0) rs2_value = 32'b0;
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
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      // Inactive payload follows the ordinary clock enable. Recovery and
      // fetch validity affect only control; a stalled bubble keeps operands.
      if (!stall) begin
        reg_q.pc       <= in.pc;
        reg_q.rs1_val  <= rs1_value;
        reg_q.rs2_val  <= rs2_value;
        reg_q.alu_a    <= dec_is_auipc ? in.pc : rs1_value;
        reg_q.alu_b    <= dec_alu_src ? imm : rs2_value;
        reg_q.imm      <= imm;
        reg_q.rd       <= in.instr[11:7];
        reg_q.rs1_addr <= in.instr[19:15];
        reg_q.rs2_addr <= in.instr[24:20];
        reg_q.instr    <= in.instr;
        reg_q.direct_target <= in.direct_target;
      end

      // Flush overrides a hold, while an unavailable fetch bubbles only
      // on advance. Clear every control bit, including prediction direction.
      if (flush || (!stall && !in.valid)) begin
        reg_q.ctrl     <= '0;
        reg_q.predicted_taken <= 1'b0;
        reg_q.valid    <= 1'b0;
      end else if (!stall) begin
        reg_q.ctrl     <= ctrl_decoded;
        reg_q.predicted_taken <= in.predicted_taken;
        reg_q.valid    <= 1'b1;
      end
    end
  end

  assign out = reg_q;

endmodule
