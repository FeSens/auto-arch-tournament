// rtl/mulh_unit.sv
//
// Iterative RV32M high-half multiplier. The hot ALU keeps only low-half MUL;
// EX starts this sidecar for MULH/MULHU/MULHSU and holds the instruction until
// done, using the same start/done/accept shape as div_unit.sv.
module mulh_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] lhs,
  input  logic [31:0] rhs,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        busy_q;
  logic        done_q;
  logic [31:0] result_q;

  logic [63:0] acc_q;
  logic [63:0] multiplicand_q;
  logic [31:0] multiplier_q;
  logic [5:0]  count_q;
  logic        result_neg_q;

  logic        signed_lhs;
  logic        signed_rhs;
  logic        result_neg;
  logic [31:0] lhs_abs;
  logic [31:0] rhs_abs;
  logic [63:0] acc_next;
  logic        product_low_zero;
  logic [31:0] product_high;

  always_comb begin
    signed_lhs = (op == ALU_MULH) || (op == ALU_MULHSU);
    signed_rhs = (op == ALU_MULH);
    result_neg = (signed_lhs && lhs[31]) ^ (signed_rhs && rhs[31]);

    lhs_abs = (signed_lhs && lhs[31]) ? (~lhs + 32'd1) : lhs;
    rhs_abs = (signed_rhs && rhs[31]) ? (~rhs + 32'd1) : rhs;

    acc_next         = multiplier_q[0] ? (acc_q + multiplicand_q) : acc_q;
    product_low_zero = (acc_next[31:0] == 32'b0);
    product_high     = result_neg_q
                     ? (~acc_next[63:32] + {31'b0, product_low_zero})
                     : acc_next[63:32];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q         <= 1'b0;
      done_q         <= 1'b0;
      result_q       <= 32'b0;
      acc_q          <= 64'b0;
      multiplicand_q <= 64'b0;
      multiplier_q   <= 32'b0;
      count_q        <= 6'b0;
      result_neg_q   <= 1'b0;
    end else begin
      if (accept && done_q) begin
        done_q <= 1'b0;
      end

      if (start && !busy_q && !done_q) begin
        busy_q         <= 1'b1;
        done_q         <= 1'b0;
        result_q       <= 32'b0;
        acc_q          <= 64'b0;
        multiplicand_q <= {32'b0, lhs_abs};
        multiplier_q   <= rhs_abs;
        count_q        <= 6'b0;
        result_neg_q   <= result_neg;
      end else if (busy_q) begin
        acc_q          <= acc_next;
        multiplicand_q <= {multiplicand_q[62:0], 1'b0};
        multiplier_q   <= {1'b0, multiplier_q[31:1]};

        if (count_q == 6'd31) begin
          busy_q   <= 1'b0;
          done_q   <= 1'b1;
          result_q <= product_high;
          count_q  <= 6'b0;
        end else begin
          count_q <= count_q + 6'd1;
        end
      end
    end
  end

  assign busy   = busy_q;
  assign done   = done_q;
  assign result = result_q;

endmodule
