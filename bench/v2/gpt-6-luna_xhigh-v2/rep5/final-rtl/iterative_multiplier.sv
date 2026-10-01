// Two-stage RV32 multiplier. Stage one registers four 16x16 products and
// the operands/op needed for signed high-half correction. Stage two sums
// the registered partial products combinationally; EX/MEM captures that
// result on the following edge. `done` and `result` remain stable until
// the EX stage consumes the result.
module iterative_multiplier (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] operand_a,
  input  logic [31:0] operand_b,
  input  logic        consume,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        result_valid_q;
  logic [31:0] pp_ll_q;
  logic [31:0] pp_lh_q;
  logic [31:0] pp_hl_q;
  logic [31:0] pp_hh_q;
  logic [31:0] operand_a_q;
  logic [31:0] operand_b_q;
  logic [4:0]  op_q;

  logic [31:0] pp_ll;
  logic [31:0] pp_lh;
  logic [31:0] pp_hl;
  logic [31:0] pp_hh;
  logic [47:0] low_sum;
  logic [63:0] high_sum;
  logic [63:0] unsigned_product;
  logic [31:0] correction_a;
  logic [31:0] correction_b;
  logic [31:0] corrected_high;
  logic [31:0] selected_result;

  always_comb begin
    pp_ll = operand_a[15:0] * operand_b[15:0];
    pp_lh = operand_a[15:0] * operand_b[31:16];
    pp_hl = operand_a[31:16] * operand_b[15:0];
    pp_hh = operand_a[31:16] * operand_b[31:16];

    low_sum = {16'b0, pp_ll_q} + {pp_lh_q, 16'b0};
    high_sum = {16'b0, pp_hl_q, 16'b0} + {pp_hh_q, 32'b0};
    unsigned_product = {16'b0, low_sum} + high_sum;

    correction_a = ((op_q == ALU_MULH || op_q == ALU_MULHSU) && operand_a_q[31])
                 ? operand_b_q : 32'b0;
    correction_b = (op_q == ALU_MULH && operand_b_q[31])
                 ? operand_a_q : 32'b0;
    corrected_high = unsigned_product[63:32] - correction_a - correction_b;

    case (op_q)
      ALU_MUL:    selected_result = unsigned_product[31:0];
      ALU_MULH,
      ALU_MULHU,
      ALU_MULHSU: selected_result = corrected_high;
      default:    selected_result = 32'b0;
    endcase
  end

  // The partial products are captured at the start edge. The combinational
  // second stage is then ready for EX/MEM on the next edge; there is no
  // additional internal busy cycle.
  assign busy   = 1'b0;
  assign done   = result_valid_q;
  assign result = selected_result;

  always_ff @(posedge clock) begin
    if (reset) begin
      result_valid_q <= 1'b0;
      pp_ll_q    <= 32'b0;
      pp_lh_q    <= 32'b0;
      pp_hl_q    <= 32'b0;
      pp_hh_q    <= 32'b0;
      operand_a_q <= 32'b0;
      operand_b_q <= 32'b0;
      op_q       <= 5'b0;
    end else if (start && !result_valid_q) begin
      result_valid_q <= 1'b1;
      pp_ll_q     <= pp_ll;
      pp_lh_q     <= pp_lh;
      pp_hl_q     <= pp_hl;
      pp_hh_q     <= pp_hh;
      operand_a_q <= operand_a;
      operand_b_q <= operand_b;
      op_q        <= op;
    end else if (consume && result_valid_q) begin
      result_valid_q <= 1'b0;
    end
  end

endmodule
