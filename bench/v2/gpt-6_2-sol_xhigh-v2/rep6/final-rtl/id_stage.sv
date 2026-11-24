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
  input  load_match_t       load_match,
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
  logic aligned_branch;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // For a decoded branch, instruction bit 8 is displacement bit 1.
  assign aligned_branch = dec_is_branch && !in.instr[8];

  // Regfile read addresses come straight from the IF/ID instruction.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.is_jump    = dec_is_jump;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  localparam operand_sel_t SELECT_LOCAL = 3'b100;
  result_kind_t result_kind;
  logic branch_recovers_in_ex, fence_i;
  logic alu_a_is_pc, alu_b_is_local;
  id_ex_t reg_q;

  assign branch_recovers_in_ex = aligned_branch && !(load_match.rs1 || load_match.rs2);
  assign fence_i = in.instr[6:0] == 7'b0001111 && in.instr[14:12] == 3'b001;
  // JAL and JALR use the ALU to form their link in parallel with the target.
  assign alu_a_is_pc = dec_is_auipc || dec_is_jump;
  assign alu_b_is_local = dec_alu_src || dec_is_jump;

  always_comb begin
    case (dec_alu_op)
      ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU: result_kind = RESULT_MUL;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:     result_kind = RESULT_DIV;
      default: result_kind = dec_mem_to_reg ? RESULT_LOAD : RESULT_FAST;
    endcase
  end

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pc          <= in.pc;
      reg_q.rs1_val     <= rs1_data;
      reg_q.rs2_val     <= rs2_data;
      reg_q.alu_a_local <= alu_a_is_pc ? in.pc : rs1_data;
      reg_q.alu_b_local <= dec_is_jump ? 32'd4 : (dec_alu_src ? imm : rs2_data);
      reg_q.rs1_sel     <= rs1_sel;
      reg_q.rs2_sel     <= rs2_sel;
      // PC and immediate operands always take the local ALU value. The
      // raw source selects above still forward those fields for RVFI.
      reg_q.alu_a_sel   <= alu_a_is_pc    ? SELECT_LOCAL : rs1_sel;
      reg_q.alu_b_sel   <= alu_b_is_local ? SELECT_LOCAL : rs2_sel;
      reg_q.imm         <= imm;
      reg_q.rd          <= in.instr[11:7];
      reg_q.rs1_addr    <= rs1_addr;
      reg_q.rs2_addr    <= rs2_addr;
      reg_q.ctrl        <= ctrl_decoded;
      reg_q.result_kind <= result_kind;
      reg_q.instr       <= in.instr;
      reg_q.predicted_taken <= in.predicted_taken;
      reg_q.branch_recover_eq     <= branch_recovers_in_ex && !dec_branch_op[2];
      reg_q.branch_recover_order  <= branch_recovers_in_ex && dec_branch_op[2];
      reg_q.branch_recover_invert <= in.predicted_taken ^ dec_branch_op[0];
      reg_q.recover_fallthrough <= in.predicted_taken || fence_i;
      reg_q.recover_direct   <= !in.predicted_taken && !dec_is_jalr && !fence_i;
      reg_q.recover_indirect <= !in.predicted_taken && dec_is_jalr;
      reg_q.fence_i     <= fence_i;
      reg_q.load_match  <= load_match;
      // The producer in EX is a load. The other branch source can come
      // from a regfile read or from the preceding instruction in MEM/WB.
      reg_q.load_other_rs1 <= !load_match.rs1 && rs1_sel.local_value;
      reg_q.load_other_rs2 <=  load_match.rs1 && rs2_sel.local_value;
      reg_q.load_other_wb  <= load_match.rs1 ? rs2_sel.mem_wb : rs1_sel.mem_wb;
    end

    if (reset)
      reg_q.valid <= 1'b0;
    else if (!stall)
      reg_q.valid <= in.valid && !flush;
  end

  assign out = reg_q;

endmodule
