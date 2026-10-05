// Stateless computational prediction. Only validation may commit a product.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module mul_predictor (
  input  logic [4:0]  op,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] a,
  input  logic [31:0] b,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] out
);
`ifndef RISCV_FORMAL_ALTOPS
  logic signed [15:0] narrow_a, narrow_b;
  logic signed [31:0] narrow_product;
  assign narrow_a = $signed(a[15:0]);
  assign narrow_b = $signed(b[15:0]);
  assign narrow_product = narrow_a * narrow_b;
`endif

  always_comb begin
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    out = $unsigned(narrow_product);
      ALU_MULH, ALU_MULHU, ALU_MULHSU: out = 32'b0;
`endif
      default: out = 32'b0;
    endcase
  end
endmodule
