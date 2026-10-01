// Shared radix-2 restoring divider for RV32 DIV/DIVU/REM/REMU.
// A request takes 32 iteration clocks after its start handshake. `done`
// remains high, with `result` stable, until `consume` is asserted.
module iterative_divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        signed_op,
  input  logic        remainder_op,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  input  logic        consume,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        active_q;
  logic        done_q;
  logic [5:0]  iter_q;
  logic [31:0] quotient_q;
  logic [31:0] divisor_q;
  logic [31:0] remainder_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;
  logic        divide_by_zero_q;
  logic        remainder_op_q;
  logic [31:0] dividend_original_q;
  logic [31:0] result_q;

  logic [31:0] dividend_magnitude;
  logic [31:0] divisor_magnitude;
  logic [32:0] trial_remainder;
  logic [32:0] divisor_extended;
  logic [31:0] remainder_step;
  logic [31:0] quotient_step;
  logic [31:0] quotient_final;
  logic [31:0] remainder_final;

  always_comb begin
    dividend_magnitude = (signed_op && dividend[31]) ? -dividend : dividend;
    divisor_magnitude  = (signed_op && divisor[31]) ? -divisor : divisor;

    trial_remainder = {remainder_q, quotient_q[31]};
    divisor_extended = {1'b0, divisor_q};
    if (trial_remainder >= divisor_extended) begin
      remainder_step = trial_remainder[31:0] - divisor_q;
      quotient_step  = {quotient_q[30:0], 1'b1};
    end else begin
      remainder_step = trial_remainder[31:0];
      quotient_step  = {quotient_q[30:0], 1'b0};
    end

    quotient_final = quotient_neg_q ? -quotient_step : quotient_step;
    remainder_final = remainder_neg_q ? -remainder_step : remainder_step;
  end

  assign busy   = active_q;
  assign done   = done_q;
  assign result = result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      active_q          <= 1'b0;
      done_q            <= 1'b0;
      iter_q            <= 6'b0;
      quotient_q        <= 32'b0;
      divisor_q         <= 32'b0;
      remainder_q       <= 32'b0;
      quotient_neg_q    <= 1'b0;
      remainder_neg_q   <= 1'b0;
      divide_by_zero_q  <= 1'b0;
      remainder_op_q    <= 1'b0;
      dividend_original_q <= 32'b0;
      result_q          <= 32'b0;
    end else if (start && !active_q && !done_q) begin
      active_q            <= 1'b1;
      iter_q              <= 6'b0;
      quotient_q          <= dividend_magnitude;
      divisor_q           <= divisor_magnitude;
      remainder_q         <= 32'b0;
      quotient_neg_q      <= signed_op && (dividend[31] ^ divisor[31]);
      remainder_neg_q     <= signed_op && dividend[31];
      divide_by_zero_q    <= (divisor == 32'b0);
      remainder_op_q      <= remainder_op;
      dividend_original_q <= dividend;
    end else if (active_q) begin
      quotient_q  <= quotient_step;
      remainder_q <= remainder_step;
      iter_q      <= iter_q + 6'd1;
      if (iter_q == 6'd31) begin
        active_q <= 1'b0;
        done_q   <= 1'b1;
        if (divide_by_zero_q) begin
          result_q <= remainder_op_q ? dividend_original_q : 32'hFFFFFFFF;
        end else begin
          result_q <= remainder_op_q ? remainder_final : quotient_final;
        end
      end
    end else if (consume && done_q) begin
      done_q <= 1'b0;
    end
  end

endmodule
