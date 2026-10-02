// Shared blocking RV32M multiplier. Launch registers unsigned 16x16
// partial products directly from the forwarded operands. The next edge
// registers the reduced result, which remains held until consumed.
module multiplier (
  input  logic        clock,
  input  logic        reset,
  input  logic        request,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 2'd0, REDUCE = 2'd1, COMPLETE = 2'd2;
  logic [1:0] state_q;
  logic [4:0] op_q;
  logic [31:0] a_q, b_q;

`ifndef RISCV_FORMAL_ALTOPS
  logic [31:0] p00_q, p01_q, p10_q, p11_q;
  logic correct_a, correct_b;
  logic [63:0] t00, t01, t10, t11, correction_a, correction_b, carry_in;
  logic [63:0] s0, c0, s1, c1, s2, c2, s3, c3, s4, c4, product;

  assign t00 = {32'b0, p00_q};
  assign t01 = {32'b0, p01_q} << 16;
  assign t10 = {32'b0, p10_q} << 16;
  assign t11 = {32'b0, p11_q} << 32;
  assign correct_a = a_q[31] && (op_q == ALU_MULH || op_q == ALU_MULHSU);
  assign correct_b = b_q[31] && op_q == ALU_MULH;
  // Subtract each original unsigned operand from the high word using
  // its complement plus a bit-32 carry. All arithmetic is modulo 2^64.
  assign correction_a = correct_a ? {~b_q, 32'b0} : 64'b0;
  assign correction_b = correct_b ? {~a_q, 32'b0} : 64'b0;
  assign carry_in = {30'b0, correct_a & correct_b, correct_a ^ correct_b, 32'b0};

  // Seven operands reduce to two without any carry propagation. Only
  // the final addition propagates carry, including cross-term carries.
  assign s0 = t00 ^ t01 ^ t10;
  assign c0 = ((t00 & t01) | (t00 & t10) | (t01 & t10)) << 1;
  assign s1 = t11 ^ correction_a ^ correction_b;
  assign c1 = ((t11 & correction_a) | (t11 & correction_b)
              | (correction_a & correction_b)) << 1;
  assign s2 = s0 ^ c0 ^ s1;
  assign c2 = ((s0 & c0) | (s0 & s1) | (c0 & s1)) << 1;
  assign s3 = c1 ^ carry_in ^ s2;
  assign c3 = ((c1 & carry_in) | (c1 & s2) | (carry_in & s2)) << 1;
  assign s4 = c2 ^ s3 ^ c3;
  assign c4 = ((c2 & s3) | (c2 & c3) | (s3 & c3)) << 1;
  assign product = s4 + c4;
`endif

  assign busy = state_q != IDLE;
  assign done = state_q == COMPLETE;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      op_q <= '0;
      a_q <= '0;
      b_q <= '0;
      result <= '0;
`ifndef RISCV_FORMAL_ALTOPS
      p00_q <= '0;
      p01_q <= '0;
      p10_q <= '0;
      p11_q <= '0;
`endif
    end else begin
      case (state_q)
        IDLE: if (request) begin
          a_q <= a;
          b_q <= b;
          op_q <= op;
`ifndef RISCV_FORMAL_ALTOPS
          // Assignment context explicitly gives every product 32 bits.
          p00_q <= a[15:0] * b[15:0];
          p01_q <= a[15:0] * b[31:16];
          p10_q <= a[31:16] * b[15:0];
          p11_q <= a[31:16] * b[31:16];
`endif
          state_q <= REDUCE;
        end
        REDUCE: begin
`ifdef RISCV_FORMAL_ALTOPS
          case (op_q)
            ALU_MUL:    result <= (a_q + b_q) ^ 32'h5876063e;
            ALU_MULH:   result <= (a_q + b_q) ^ 32'hf6583fb7;
            ALU_MULHU:  result <= (a_q + b_q) ^ 32'h949ce5e8;
            ALU_MULHSU: result <= (a_q - b_q) ^ 32'hecfbe137;
            default:    result <= '0;
          endcase
`else
          result <= op_q == ALU_MUL ? product[31:0] : product[63:32];
`endif
          state_q <= COMPLETE;
        end
        COMPLETE: if (consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
