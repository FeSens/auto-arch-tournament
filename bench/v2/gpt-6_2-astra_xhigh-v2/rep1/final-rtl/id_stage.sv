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
  input  logic              bubble,
  input  logic              capture_replay,
  input  logic [31:0]       ex_rs1,
  input  logic [31:0]       ex_rs2,
  input  if_id_t  in,
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

  // Regfile and forwarding tags use the selected fetch word.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_is_jump ? ALU_LUI : dec_alu_op;
    ctrl_decoded.alu_src    = dec_is_jump || dec_alu_src;
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
    ctrl_decoded.mem_to_reg = dec_mem_to_reg || is_multiply(dec_alu_op);
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset)       reg_q.valid <= 1'b0;
    else if (!stall) reg_q.valid <= in.valid && !bubble;

    if (capture_replay) begin
      reg_q.rs1_val <= ex_rs1;
      reg_q.rs2_val <= ex_rs2;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.prediction <= in.prediction;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_data;
      reg_q.imm      <= imm;
      reg_q.alu_imm  <= dec_is_jump ? in.fallthrough : imm;
      reg_q.is_add   <= in.instr[14:12] == 3'b000 &&
                        (in.instr[6:0] == 7'h13 ||
                        (in.instr[6:0] == 7'h33 && in.instr[31:25] == 0));
      reg_q.is_div   <= in.instr[6:0] == 7'h33 && in.instr[31:25] == 1 && in.instr[14];
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
    end
  end

  // A bubble carries decoded data. Gate the controls that can redirect,
  // request memory, interlock a younger instruction, or supply a result.
  always_comb begin
    out = reg_q;
    out.ctrl.is_branch = reg_q.valid && reg_q.ctrl.is_branch;
    out.ctrl.is_jump   = reg_q.valid && reg_q.ctrl.is_jump;
    out.ctrl.mem_read  = reg_q.valid && reg_q.ctrl.mem_read;
    out.ctrl.mem_write = reg_q.valid && reg_q.ctrl.mem_write;
    out.ctrl.reg_write = reg_q.valid && reg_q.ctrl.reg_write;
  end

endmodule
