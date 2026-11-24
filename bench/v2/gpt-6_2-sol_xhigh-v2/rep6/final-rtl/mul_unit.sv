// EX half of RV32M multiplication. The EX/MEM register captures the products.
module mul_unit (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output mul_products_t products
);

`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    case (op)
      ALU_MUL:    products.alternate = (a + b) ^ 32'h5876063e;
      ALU_MULH:   products.alternate = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  products.alternate = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: products.alternate = (a - b) ^ 32'hecfbe137;
      default:    products.alternate = 32'b0;
    endcase
  end
`else
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;

  assign a_lo = {1'b0, a[15:0]};
  assign b_lo = {1'b0, b[15:0]};
  assign a_hi = {a[31] && (op == ALU_MULH || op == ALU_MULHSU), a[31:16]};
  assign b_hi = {b[31] && (op == ALU_MULH), b[31:16]};

  assign products.lo_lo = a_lo * b_lo;
  assign products.lo_hi = a_lo * b_hi;
  assign products.hi_lo = a_hi * b_lo;
  assign products.hi_hi = a_hi * b_hi;
  assign products.high_half = op != ALU_MUL;
`endif

endmodule
