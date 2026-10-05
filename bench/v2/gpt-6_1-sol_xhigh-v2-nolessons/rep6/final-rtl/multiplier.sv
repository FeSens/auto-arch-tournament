// Combinational MEM completion lane, using captured forwarded operands.
// One signedness-selectable 33-by-33 product implements all RV32M modes.
module multiplier (
  input  logic [4:0]  op,
  input  logic [31:0] rs1_val,
  input  logic [31:0] rs2_val,
  output logic [31:0] result
);
`ifndef RISCV_FORMAL_ALTOPS
  logic a_signed, b_signed;
  logic signed [32:0] mul_a, mul_b;
  // The extension-only product bits [65:64] are intentionally unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] product;
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  always_comb begin
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_MUL:    result = (rs1_val + rs2_val) ^ 32'h5876063e;
      ALU_MULH:   result = (rs1_val + rs2_val) ^ 32'hf6583fb7;
      ALU_MULHU:  result = (rs1_val + rs2_val) ^ 32'h949ce5e8;
      ALU_MULHSU: result = (rs1_val - rs2_val) ^ 32'hecfbe137;
      default:    result = 32'b0;
    endcase
`else
    a_signed = (op == ALU_MULH || op == ALU_MULHSU);
    b_signed = (op == ALU_MULH);
    mul_a = $signed({a_signed && rs1_val[31], rs1_val});
    mul_b = $signed({b_signed && rs2_val[31], rs2_val});
    product = mul_a * mul_b;
    case (op)
      ALU_MUL: result = product[31:0];
      ALU_MULH, ALU_MULHU, ALU_MULHSU: result = product[63:32];
      default: result = 32'b0;
    endcase
`endif
  end
endmodule
