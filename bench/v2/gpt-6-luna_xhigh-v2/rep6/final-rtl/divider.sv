// Shared radix-2 restoring divider. One dividend bit is processed each
// active cycle; start captures operands and completion follows 32 steps.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        signed_mode,
  input  logic        remainder_mode,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        busy_q;
  logic [5:0]  count_q;
  logic [31:0] quotient_q;
  logic [31:0] remainder_q;
  logic [31:0] divisor_q;
  logic        quotient_negative_q;
  logic        remainder_negative_q;
  logic        remainder_mode_q;
  logic        divide_by_zero_q;

  logic [32:0] shifted_remainder;
  logic [31:0] remainder_next;
  logic [31:0] quotient_next;
  logic [31:0] unsigned_result;
  logic [31:0] signed_result;

  always_comb begin
    shifted_remainder = {remainder_q[31:0], quotient_q[31]};
    if (shifted_remainder >= {1'b0, divisor_q}) begin
      remainder_next = shifted_remainder[31:0] - divisor_q;
      quotient_next  = {quotient_q[30:0], 1'b1};
    end else begin
      remainder_next = shifted_remainder[31:0];
      quotient_next  = {quotient_q[30:0], 1'b0};
    end

    unsigned_result = remainder_mode_q ? remainder_next
                                       : quotient_next;
    if (divide_by_zero_q && !remainder_mode_q)
      unsigned_result = 32'hFFFFFFFF;

    signed_result = unsigned_result;
    if (remainder_mode_q && remainder_negative_q)
      signed_result = -unsigned_result;
    else if (!remainder_mode_q && quotient_negative_q &&
             !divide_by_zero_q)
      signed_result = -unsigned_result;

    done   = busy_q && (count_q == 6'd31);
  end

  // signed_mode is captured so the result stays independent of input changes
  // while the operation is running.
  logic signed_mode_q;
  always_comb begin
    result = signed_mode_q ? signed_result : unsigned_result;
  end

  assign busy = busy_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q               <= 1'b0;
      count_q              <= 6'b0;
      quotient_q           <= 32'b0;
      remainder_q          <= 32'b0;
      divisor_q            <= 32'b0;
      quotient_negative_q  <= 1'b0;
      remainder_negative_q <= 1'b0;
      remainder_mode_q     <= 1'b0;
      divide_by_zero_q     <= 1'b0;
      signed_mode_q        <= 1'b0;
    end else if (!busy_q && start) begin
      busy_q               <= 1'b1;
      count_q              <= 6'b0;
      quotient_q           <= (signed_mode && dividend[31]) ? -dividend : dividend;
      remainder_q          <= 32'b0;
      divisor_q            <= (signed_mode && divisor[31]) ? -divisor : divisor;
      quotient_negative_q  <= signed_mode && (dividend[31] ^ divisor[31]);
      remainder_negative_q <= signed_mode && dividend[31];
      remainder_mode_q     <= remainder_mode;
      divide_by_zero_q     <= (divisor == 32'b0);
      signed_mode_q        <= signed_mode;
    end else if (busy_q) begin
      quotient_q  <= quotient_next;
      remainder_q <= remainder_next;
      if (count_q == 6'd31)
        busy_q <= 1'b0;
      else
        count_q <= count_q + 6'd1;
    end
  end

endmodule
