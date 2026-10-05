// MEM validation uses the original registered, full-width source operands.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module mul_exact (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);
`ifndef RISCV_FORMAL_ALTOPS
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;
  logic        [63:0] mul_uu;
  logic signed [63:0] mul_su;
  /* verilator lint_on UNUSEDSIGNAL */
  // Keep the standalone ALU's widths and signed/unsigned semantics.
  assign mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
  assign mul_uu = {32'b0, a} * {32'b0, b};
  assign mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
`endif

  always_comb begin
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
`endif
      default: out = 32'b0;
    endcase
  end
endmodule
