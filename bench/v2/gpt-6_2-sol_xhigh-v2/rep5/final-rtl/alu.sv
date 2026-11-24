// rtl/alu.sv
//
// Combinational ALU for RV32I.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata through EX/MEM and MEM/WB.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif

module alu #(
  parameter bit REGISTERED_SELECT = 1'b0
) (
  input  logic [4:0]  op,
  input  alu_select_t selects,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  alu_select_t sel;
  logic [31:0] shift_right;

  assign sel = REGISTERED_SELECT ? selects : decode_alu(op);
  assign shift_right = 32'($signed({sel.sra && a[31], a}) >>> b[4:0]);
  assign out = ({32{sel.add}} & (a + b))
             | ({32{sel.sub}} & (a - b))
             | ({32{sel.and_op}} & (a & b))
             | ({32{sel.or_op}} & (a | b))
             | ({32{sel.xor_op}} & (a ^ b))
             | {31'b0, (sel.slt && $signed(a) < $signed(b)) || (sel.sltu && a < b)}
             | ({32{sel.sll}} & (a << b[4:0]))
             | ({32{sel.srl || sel.sra}} & shift_right)
             | ({32{sel.lui}} & b);

endmodule
