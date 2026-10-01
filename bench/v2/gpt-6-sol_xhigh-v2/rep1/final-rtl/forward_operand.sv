// Fused EX/MEM result-bank selection and EX operand forwarding.
// The enable vector is registered beside ID/EX and EX/MEM; exactly one
// bank, the MEM/WB value, or the held ID/EX value is enabled per source.
module forward_operand (
  input  logic [21:0] enable,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t     banks,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] wb_value,
  input  logic [31:0] held_value,
  output logic [31:0] value
);
  logic [31:0] group0, group1, group2, group3, group4;
  logic [31:0] other_value;

  assign group0 =
      ({32{enable[ALU_SUB]}} & banks.sub_result) |
      ({32{enable[ALU_AND]}} & banks.and_result) |
      ({32{enable[ALU_OR]}}  & banks.or_result) |
      ({32{enable[ALU_XOR]}} & banks.xor_result);
  assign group1 =
      ({32{enable[ALU_SLT]}}  & {31'b0, banks.slt_result}) |
      ({32{enable[ALU_SLTU]}} & {31'b0, banks.sltu_result}) |
      ({32{enable[ALU_SLL]}}  & banks.sll_result) |
      ({32{enable[ALU_SRL]}}  & banks.srl_result);
  assign group2 =
      ({32{enable[ALU_SRA]}} & banks.sra_result) |
      ({32{enable[ALU_LUI]}} & banks.lui_result) |
      ({32{enable[19]}} & banks.link_result);
`ifdef RISCV_FORMAL_ALTOPS
  assign group3 = {32{(|enable[18:11])}} & banks.alt_result;
  assign group4 = 32'b0;
`else
  assign group3 =
      ({32{enable[ALU_MUL]}}    & banks.mul_result) |
      ({32{enable[ALU_MULHU]}}  & banks.mulhu_result);
  assign group4 = {32{(|enable[18:15])}} & banks.div_result;
`endif
  assign other_value = ((group0 | group1) | (group2 | group3)) | group4;
  // ADD and high signed products bypass the grouped result tree. Their
  // selects feed both DSP operands and the general EX result banks.
  assign value = other_value |
      ({32{enable[ALU_ADD]}} & banks.add_result) |
`ifndef RISCV_FORMAL_ALTOPS
      ({32{enable[ALU_MULH]}} & banks.mulh_result) |
      ({32{enable[ALU_MULHSU]}} & banks.mulhsu_result) |
`endif
      ({32{enable[20]}} & wb_value) |
      ({32{enable[21]}} & held_value);
endmodule
