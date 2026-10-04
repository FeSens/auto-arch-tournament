// Shared RV32M multiplier. Launch captures operands; two busy clocks
// register halfword products and then the final result. A completed
// result stays valid and stable until accepted, independently of MEM.
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
  logic products_ready_q;
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q, launch_result;
  always_comb begin
    case (op)
      ALU_MUL:    launch_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   launch_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  launch_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: launch_result = (a - b) ^ 32'hecfbe137;
      default:    launch_result = 32'b0;
    endcase
  end
`else
  logic [15:0] a_lo_q, b_lo_q;
  logic signed [16:0] a_hi_q, b_hi_q;
  logic select_low_q;
  logic [31:0] p00_q;
  logic signed [32:0] p01_q, p10_q;
  // The upper two bits are redundant modulo 2^32 in the high result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [33:0] p11_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [33:0] cross_x, cross_y, cross_z, cross_sum, cross_carry;
  logic signed [33:0] cross_term;
  logic [31:0] low_result, high_result;

  // One carry-save layer, followed by one 34-bit carry-propagate sum.
  // Keep both the signed cross products and the p00 carry at full width.
  assign cross_x = {p01_q[32], p01_q};
  assign cross_y = {p10_q[32], p10_q};
  assign cross_z = {18'b0, p00_q[31:16]};
  assign cross_sum = cross_x ^ cross_y ^ cross_z;
  assign cross_carry = ((cross_x & cross_y) | (cross_x & cross_z)
                      | (cross_y & cross_z)) << 1;
  assign cross_term = $signed(cross_sum + cross_carry);
  assign low_result = {cross_term[15:0], p00_q[15:0]};
  assign high_result = p11_q[31:0]
                     + {{14{cross_term[33]}}, cross_term[33:16]};
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      busy <= 1'b0;
      result_valid <= 1'b0;
      result <= 32'b0;
      products_ready_q <= 1'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result_q <= 32'b0;
`else
      a_lo_q <= 16'b0;
      b_lo_q <= 16'b0;
      a_hi_q <= 17'sb0;
      b_hi_q <= 17'sb0;
      select_low_q <= 1'b0;
      p00_q <= 32'b0;
      p01_q <= 33'sb0;
      p10_q <= 33'sb0;
      p11_q <= 34'sb0;
`endif
    end else begin
      if (result_accept) result_valid <= 1'b0;
      // Acceptance and a new launch can share an edge without rearming.
      if (start && !busy && (!result_valid || result_accept)) begin
        busy <= 1'b1;
        result_valid <= 1'b0;
        products_ready_q <= 1'b0;
`ifdef RISCV_FORMAL_ALTOPS
        alt_result_q <= launch_result;
`else
        a_lo_q <= a[15:0];
        b_lo_q <= b[15:0];
        a_hi_q <= {(op == ALU_MULH || op == ALU_MULHSU) && a[31], a[31:16]};
        b_hi_q <= {(op == ALU_MULH) && b[31], b[31:16]};
        select_low_q <= (op == ALU_MUL);
`endif
      end else if (busy) begin
        if (!products_ready_q) begin
`ifndef RISCV_FORMAL_ALTOPS
          p00_q <= a_lo_q * b_lo_q;
          p01_q <= $signed({1'b0, a_lo_q}) * b_hi_q;
          p10_q <= a_hi_q * $signed({1'b0, b_lo_q});
          p11_q <= a_hi_q * b_hi_q;
`endif
          products_ready_q <= 1'b1;
        end else begin
          busy <= 1'b0;
          result_valid <= 1'b1;
`ifdef RISCV_FORMAL_ALTOPS
          result <= alt_result_q;
`else
          result <= select_low_q ? low_result : high_result;
`endif
        end
      end
    end
  end
endmodule
