// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// fully resolved source data. The ID/EX register is owned by this module so
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
  // Raw regfile addresses and resolved architectural operand inputs.
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

  // Raw regfile read addresses and decode stay independent of fetch-valid.
  // The hazard unit separately qualifies load-use detection with valid.
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
  id_ex_t decoded;

  always_comb begin
    decoded.pc       = in.pc;
    decoded.direct_target = in.direct_target;
    decoded.fallthrough_pc = in.fallthrough_pc;
    decoded.predicted_transfer = in.predicted_transfer;
    decoded.recovery_pc = in.recovery_pc;
    decoded.rs1_val  = rs1_data;
    decoded.rs2_val  = rs2_data;
    decoded.alu_a    = dec_is_auipc ? in.pc : rs1_data;
    decoded.alu_b    = dec_alu_src ? imm : rs2_data;
    decoded.mul_class = dec_alu_op == ALU_MUL || dec_alu_op == ALU_MULH
                        || dec_alu_op == ALU_MULHU || dec_alu_op == ALU_MULHSU;
    decoded.div_class = dec_alu_op == ALU_DIV || dec_alu_op == ALU_DIVU
                        || dec_alu_op == ALU_REM || dec_alu_op == ALU_REMU;
    decoded.fast_write = dec_reg_write && !dec_mem_read && !dec_is_illegal
                         && !decoded.mul_class && !decoded.div_class;
    decoded.imm      = imm;
    decoded.rd       = in.instr[11:7];
    decoded.rs1_addr = in.instr[19:15];
    decoded.rs2_addr = in.instr[24:20];
    decoded.ctrl     = ctrl_decoded;
    decoded.instr    = in.instr;
    decoded.valid    = in.valid;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      // Raw payload data and its enable never depend on flush/valid.
      // A load-use flush holds payload but still kills controls below.
      if (!stall) begin
        reg_q.pc <= decoded.pc;
        reg_q.direct_target <= decoded.direct_target;
        reg_q.fallthrough_pc <= decoded.fallthrough_pc;
        reg_q.predicted_transfer <= decoded.predicted_transfer;
        reg_q.recovery_pc <= decoded.recovery_pc;
        reg_q.rs1_val <= decoded.rs1_val;
        reg_q.rs2_val <= decoded.rs2_val;
        reg_q.alu_a <= decoded.alu_a;
        reg_q.alu_b <= decoded.alu_b;
        reg_q.imm <= decoded.imm;
        reg_q.rd <= decoded.rd;
        reg_q.rs1_addr <= decoded.rs1_addr;
        reg_q.rs2_addr <= decoded.rs2_addr;
        reg_q.instr <= decoded.instr;
      end
      // Flush wins over hold to inject a real load-use bubble. All
      // side-effect eligibility is cleared even though raw payload stays.
      if (flush || (!stall && !in.valid)) begin
        reg_q.valid <= 1'b0;
        reg_q.ctrl <= '0;
        reg_q.fast_write <= 1'b0;
        reg_q.mul_class <= 1'b0;
        reg_q.div_class <= 1'b0;
      end else if (!stall) begin
        reg_q.valid <= decoded.valid;
        reg_q.ctrl <= decoded.ctrl;
        reg_q.fast_write <= decoded.fast_write;
        reg_q.mul_class <= decoded.mul_class;
        reg_q.div_class <= decoded.div_class;
      end
    end
  end

  assign out = reg_q;

endmodule
