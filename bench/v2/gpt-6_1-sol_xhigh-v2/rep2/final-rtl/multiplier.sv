// Blocking RV32M multiplier: capture, registered unsigned product, transfer.
// Operands, operation and product remain stable until the response is taken.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module multiplier (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [31:0] result
);
  logic busy_q;
  logic [31:0] a_q, b_q;
  logic [4:0] op_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] arithmetic_q;

  always_comb begin
    case (op_q)
      ALU_MUL:    result = arithmetic_q ^ 32'h5876063e;
      ALU_MULH:   result = arithmetic_q ^ 32'hf6583fb7;
      ALU_MULHU:  result = arithmetic_q ^ 32'h949ce5e8;
      ALU_MULHSU: result = arithmetic_q ^ 32'hecfbe137;
      default:    result = 32'b0;
    endcase
  end
`else
  logic [63:0] product_q;
  logic [31:0] correction_a, correction_b;
  logic [31:0] sum_first, carry_first, sum_final, carry_final;
  logic [31:0] signed_high;

  // Uhi - (a_negative ? b : 0) - (b_negative ? a : 0), modulo 2^32.
  // Two complemented correction terms contribute a constant +2. Reduce
  // all operands with carry-save logic before one carry-propagate adder.
  assign correction_a = a_q[31] ? ~b_q : 32'hffffffff;
  assign correction_b = (op_q == ALU_MULH && b_q[31])
                      ? ~a_q : 32'hffffffff;
  assign sum_first = product_q[63:32] ^ correction_a ^ correction_b;
  assign carry_first = ((product_q[63:32] & correction_a) |
                        (product_q[63:32] & correction_b) |
                        (correction_a & correction_b)) << 1;
  assign sum_final = sum_first ^ carry_first ^ 32'd2;
  assign carry_final = ((sum_first & carry_first) |
                        (sum_first & 32'd2) | (carry_first & 32'd2)) << 1;
  assign signed_high = sum_final + carry_final;

  always_comb begin
    case (op_q)
      ALU_MUL:    result = product_q[31:0];
      ALU_MULHU:  result = product_q[63:32];
      ALU_MULH, ALU_MULHSU: result = signed_high;
      default:    result = 32'b0;
    endcase
  end
`endif

  assign req_ready = !busy_q && !rsp_valid;

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q <= 1'b0;
      rsp_valid <= 1'b0;
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
      arithmetic_q <= '0;
`else
      product_q <= '0;
`endif
    end else begin
      if (rsp_valid && rsp_ready)
        rsp_valid <= 1'b0;
      if (req_valid && req_ready) begin
        busy_q <= 1'b1;
        a_q <= a;
        b_q <= b;
        op_q <= op;
      end else if (busy_q) begin
        busy_q <= 1'b0;
        rsp_valid <= 1'b1;
`ifdef RISCV_FORMAL_ALTOPS
        arithmetic_q <= (op_q == ALU_MULHSU) ? a_q - b_q : a_q + b_q;
`else
        // The only multiplication in the core: unsigned 32 x 32 -> 64.
        product_q <= a_q * b_q;
`endif
      end
    end
  end
endmodule
