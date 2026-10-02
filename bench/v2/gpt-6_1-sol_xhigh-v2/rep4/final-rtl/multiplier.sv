// MEM product channel. Inputs are exclusively the EX/MEM operand registers;
// MEM/WB captures the selected product on the next normal pipeline edge.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module multiplier (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] result
);
`ifndef RISCV_FORMAL_ALTOPS
  // Keep the established widened expressions and their DSP inference.
  // Only the high halves of signed products are architecturally consumed.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;
  logic        [63:0] mul_uu;
  logic signed [63:0] mul_su;
  /* verilator lint_on UNUSEDSIGNAL */
  assign mul_ss = $signed({{32{a[31]}}, a}) *
                  $signed({{32{b[31]}}, b});
  assign mul_uu = {32'b0, a} * {32'b0, b};
  assign mul_su = $signed({{32{a[31]}}, a}) *
                  $signed({32'b0, b});
`endif
  always_comb begin
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: result = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    result = mul_uu[31:0];
      ALU_MULH:   result = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  result = mul_uu[63:32];
      ALU_MULHSU: result = $unsigned(mul_su[63:32]);
`endif
      default:    result = 32'b0;
    endcase
  end
endmodule
