// Blocking RV32M multiplier: launch registers four signed 17x17 limb
// products; service edge two accepts their carry-save recombination.
// Partials and source snapshots remain frozen until acceptance or reset.
module mul_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        result_valid,
  output logic [31:0] result,
  input  logic        result_accept
);
  logic pending;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] a_q, b_q;
  logic [4:0] op_q;
  /* verilator lint_on UNUSEDSIGNAL */

`ifndef RISCV_FORMAL_ALTOPS
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
  logic signed [33:0] ll_q, lh_q, hl_q, hh_q;
  logic high_q;
  logic [63:0] p0, p1, p2, p3, sum1, carry1, sum2, carry2, product;

  assign a_lo = $signed({1'b0, a[15:0]});
  assign b_lo = $signed({1'b0, b[15:0]});
  assign a_hi = $signed({((op == ALU_MULH || op == ALU_MULHSU) && a[31]), a[31:16]});
  assign b_hi = $signed({((op == ALU_MULH) && b[31]), b[31:16]});

  // Sign extension must precede alignment, including for mixed products.
  // Arithmetic is modulo 2^64; the high limb's top two bits shift out.
  assign p0 = {{30{ll_q[33]}}, ll_q};
  assign p1 = {{30{lh_q[33]}}, lh_q} << 16;
  assign p2 = {{30{hl_q[33]}}, hl_q} << 16;
  assign p3 = {{30{hh_q[33]}}, hh_q} << 32;
  assign sum1 = p0 ^ p1 ^ p2;
  assign carry1 = ((p0 & p1) | (p0 & p2) | (p1 & p2)) << 1;
  assign sum2 = sum1 ^ carry1 ^ p3;
  assign carry2 = ((sum1 & carry1) | (sum1 & p3) | (carry1 & p3)) << 1;
  assign product = sum2 + carry2;
  assign result = high_q ? product[63:32] : product[31:0];
`else
  always_comb begin
    case (op_q)
      ALU_MUL:    result = (a_q + b_q) ^ 32'h5876063e;
      ALU_MULH:   result = (a_q + b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  result = (a_q + b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: result = (a_q - b_q) ^ 32'hecfbe137;
      default:    result = '0;
    endcase
  end
`endif

  assign busy = pending;
  assign result_valid = pending;

  always_ff @(posedge clock) begin
    if (reset) begin
      pending <= 1'b0;
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
`ifndef RISCV_FORMAL_ALTOPS
      ll_q <= '0;
      lh_q <= '0;
      hl_q <= '0;
      hh_q <= '0;
      high_q <= 1'b0;
`endif
    end else if (pending) begin
      // Busy starts never replace pending work, including the accept edge.
      if (result_accept) pending <= 1'b0;
    end else if (start) begin
      pending <= 1'b1;
      a_q <= a;
      b_q <= b;
      op_q <= op;
`ifndef RISCV_FORMAL_ALTOPS
      ll_q <= a_lo * b_lo;
      lh_q <= a_lo * b_hi;
      hl_q <= a_hi * b_lo;
      hh_q <= a_hi * b_hi;
      high_q <= op != ALU_MUL;
`endif
    end
  end
endmodule
