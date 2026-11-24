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
  output logic              dec_alu_src,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  input  logic              wb_en,
  input  logic [4:0]        wb_rd,
  input  logic [31:0]       wb_value,
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  logic [4:0]  dec_alu_op;
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

  id_ex_t reg_q;
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
  logic   is_fence_i;
  assign is_fence_i = in.instr[6:0] == 7'b0001111 && in.instr[14:12] == 3'b001;

  always_ff @(posedge clock) begin
    // A held operand only changes when an older instruction writes it.
    // This keeps MEM verification off both register-file address paths.
    if (!stall) begin
      reg_q.rs1_val <= rs1_data;
      reg_q.rs2_val <= rs2_data;
    end else if (wb_en && wb_rd != 0) begin
      if (wb_rd == reg_q.rs1_addr) reg_q.rs1_val <= wb_value;
      if (wb_rd == reg_q.rs2_addr) reg_q.rs2_val <= wb_value;
    end
    if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.instr    <= in.instr;
      reg_q.is_fence_i          <= is_fence_i;
      reg_q.wb_only             <= in.instr[6:0] == 7'h33 && in.instr[31:25] == 7'h01;
      reg_q.recover_fallthrough <= in.predicted_taken || is_fence_i;
      reg_q.direction_counter <= in.direction_counter;
      reg_q.ctrl     <= ctrl_decoded;
    end

    // Only the valid bit depends on the late EX correction. EX kills
    // side-effect controls before an invalid slot enters MEM.
    if (reset) begin
      reg_q.valid <= 1'b0;
    end else if (!stall) begin
      reg_q.valid <= in.valid && !flush;
    end
  end

  assign out = reg_q;

endmodule
