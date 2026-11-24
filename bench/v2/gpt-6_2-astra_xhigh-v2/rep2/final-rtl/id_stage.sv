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
  input  logic              use_rf, use_mem, use_add, use_lui, use_lw,
  input  logic [31:0]       mem_result, ex_a, ex_b, lw_word,
  input  logic              repair,
  input  logic [31:0]       repaired_addr,
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
  logic        unused_mem_to_reg;
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
    .mem_to_reg (unused_mem_to_reg),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for late-result detection.
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
    // All eight funct3 values of OP with funct7=1 are legal M operations.
    ctrl_decoded.late_result = in.instr[6:0] == 7'b0110011 && in.instr[31:25] == 7'b0000001;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // Only LOAD and STORE use these candidates. Bit 5 distinguishes their
  // immediate encodings. A signed 12-bit offset can cross at most one
  // page, so a change of bit 12 detects both carry and borrow.
  logic [12:0] disp, rf_sum, mem_sum, lw_sum;
  assign disp = {in.instr[31], in.instr[31:25],
                 in.instr[5] ? in.instr[11:7] : in.instr[24:20]};
  assign rf_sum  = rs1_data[12:0] + disp;
  assign mem_sum = mem_result[12:0] + disp;
  assign lw_sum  = lw_word[12:0] + disp;

  // For an ADD/ADDI/AUIPC producer the page needs the carry from A+B.
  // Compress A+B+disp independently so its low sum doesn't wait for A+B.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] add_base;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [12:0] ab_xor, carry, add_sum;
  assign add_base = ex_a + ex_b;
  assign ab_xor   = ex_a[12:0] ^ ex_b[12:0];
  assign carry    = ((ex_a[12:0] & ex_b[12:0]) | (ab_xor & disp)) << 1;
  assign add_sum  = (ab_xor ^ disp) + carry;

  logic [19:0] page;
  logic [12:0] low_sum;
  assign page = ({20{use_rf}}  & rs1_data[31:12])
              | ({20{use_mem}} & mem_result[31:12])
              | ({20{use_add}} & add_base[31:12])
              | ({20{use_lui}} & ex_b[31:12])
              | ({20{use_lw}}  & lw_word[31:12]);
  assign low_sum = ({13{use_rf}}  & rf_sum)
                 | ({13{use_mem}} & mem_sum)
                 | ({13{use_add}} & add_sum)
                 | ({13{use_lui}} & {ex_b[12] ^ disp[12], disp[11:0]})
                 | ({13{use_lw}}  & lw_sum);

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q.ctrl  <= '0;
      reg_q.valid <= 1'b0;
    end else if (!stall) begin
      reg_q.ctrl  <= ctrl_decoded;
      reg_q.valid <= in.valid;
    end
    if (repair)
      reg_q.mem_addr <= repaired_addr;
    else if (!stall)
      reg_q.mem_addr <= {page, low_sum[11:0]};

    if (!stall) begin
      reg_q.page_cross <= low_sum[12] ^ page[0];
      reg_q.base_available <= use_rf || use_mem || use_add || use_lui || use_lw;
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_data;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.instr    <= in.instr;
    end
  end

  assign out = reg_q;

endmodule
