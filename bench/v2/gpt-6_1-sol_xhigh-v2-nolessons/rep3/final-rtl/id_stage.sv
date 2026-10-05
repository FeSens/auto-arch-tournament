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
  input  logic              stall,           // older memory or divider owns EX
  input  logic              flush,           // redirect or load-use validity kill
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Validated incoming controls, before the ID/EX capture edge.
  output logic             incoming_alu_src,
  output logic             incoming_is_auipc,
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
  assign incoming_alu_src = dec_alu_src || dec_is_branch;
  assign incoming_is_auipc = dec_is_auipc;

  ctrl_t ctrl_decoded;
  always_comb begin
    // A conditional branch has no rd result. The ordinary LUI datapath
    // carries its prepared alternate PC into the arithmetic result lane.
    ctrl_decoded.alu_op     = dec_is_branch ? ALU_LUI : dec_alu_op;
    ctrl_decoded.alu_src    = incoming_alu_src;
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
      // Payload holds only for genuine downstream ownership. A validity
      // kill never clears data or controls this wide register's enable.
      if (!stall) begin
        reg_q.pc       <= in.pc;
        reg_q.rs1_val  <= rs1_data;
        reg_q.rs2_val  <= rs2_data;
        reg_q.imm      <= (dec_is_branch || (dec_is_jump && !dec_is_jalr))
                        ? in.recovery_addr : imm;
        reg_q.predicted_taken <= in.predicted_taken;
        reg_q.direct_aligned <= in.direct_aligned;
        reg_q.mismatch_op <= dec_branch_op ^ {2'b00, in.predicted_taken};
        reg_q.rd       <= in.instr[11:7];
        reg_q.rs1_addr <= in.instr[19:15];
        reg_q.rs2_addr <= in.instr[24:20];
        reg_q.is_multiply <= !dec_is_illegal &&
                            (dec_alu_op == ALU_MUL || dec_alu_op == ALU_MULH ||
                             dec_alu_op == ALU_MULHU || dec_alu_op == ALU_MULHSU);
        reg_q.is_divide <= !dec_is_illegal &&
                          (dec_alu_op == ALU_DIV || dec_alu_op == ALU_DIVU ||
                           dec_alu_op == ALU_REM || dec_alu_op == ALU_REMU);
        for (int j = 0; j < 11; j++) begin
          reg_q.result_grants[j] <= !ctrl_decoded.is_jump &&
                                    ctrl_decoded.alu_op == 5'(j);
        end
        reg_q.result_grants[11] <= ctrl_decoded.is_jump;
        reg_q.ctrl     <= ctrl_decoded;
        reg_q.instr    <= in.instr;
      end
      if (flush)       reg_q.valid <= 1'b0;
      else if (!stall) reg_q.valid <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
