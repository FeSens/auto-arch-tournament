// Shared radix-2 unsigned core for RV32 DIV/DIVU/REM/REMU.
// The operands are converted to magnitudes at start and sign correction is
// applied once after the final quotient/remainder bit has been generated.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic        signed_mode,
  input  logic        remainder_mode,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] IDLE = 2'd0;
  localparam logic [1:0] RUN  = 2'd1;
  localparam logic [1:0] DONE = 2'd2;

  logic [1:0] state_q;
  logic [4:0] count_q;
  logic [31:0] quotient_q;
  logic [31:0] divisor_q;
  logic [31:0] remainder_q;
  logic quotient_negative_q;
  logic remainder_negative_q;
  logic remainder_mode_q;
  logic [31:0] result_q;

  logic dividend_negative;
  logic divisor_negative;
  logic [31:0] dividend_magnitude;
  logic [31:0] divisor_magnitude;
  logic [32:0] trial_remainder;
  logic [31:0] reduced_remainder;
  logic [31:0] quotient_next;
  logic [31:0] magnitude_result;
  logic [31:0] corrected_result;

  always_comb begin
    dividend_negative = signed_mode && dividend[31];
    divisor_negative  = signed_mode && divisor[31];
    dividend_magnitude = dividend_negative ? (~dividend + 32'd1) : dividend;
    divisor_magnitude  = divisor_negative  ? (~divisor  + 32'd1) : divisor;

    trial_remainder = {remainder_q, quotient_q[31]};
    if (trial_remainder >= {1'b0, divisor_q}) begin
      // The restored value is strictly less than divisor_q (32 bits), so
      // its upper bit is zero and the low 32 bits are the full result.
      reduced_remainder = trial_remainder[31:0] - divisor_q;
      quotient_next = {quotient_q[30:0], 1'b1};
    end else begin
      reduced_remainder = trial_remainder[31:0];
      quotient_next = {quotient_q[30:0], 1'b0};
    end

    magnitude_result = remainder_mode_q ? reduced_remainder
                                        : quotient_next;
    if (remainder_mode_q ? remainder_negative_q : quotient_negative_q)
      corrected_result = ~magnitude_result + 32'd1;
    else
      corrected_result = magnitude_result;
  end

  assign busy   = (state_q == RUN);
  assign done   = (state_q == DONE);
  assign result = result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q              <= IDLE;
      count_q              <= 5'b0;
      quotient_q           <= 32'b0;
      divisor_q            <= 32'b0;
      remainder_q          <= 32'b0;
      quotient_negative_q  <= 1'b0;
      remainder_negative_q <= 1'b0;
      remainder_mode_q     <= 1'b0;
      result_q             <= 32'b0;
    end else begin
      case (state_q)
        IDLE: begin
          if (start) begin
            quotient_negative_q  <= dividend_negative ^ divisor_negative;
            remainder_negative_q <= dividend_negative;
            remainder_mode_q     <= remainder_mode;
            remainder_q          <= 32'b0;
            count_q              <= 5'b0;
            if (divisor == 32'b0) begin
              // RV32M defines quotient by zero as all ones and remainder
              // by zero as the original dividend, signed or unsigned.
              result_q <= remainder_mode ? dividend : 32'hFFFFFFFF;
              state_q  <= DONE;
            end else begin
              quotient_q <= dividend_magnitude;
              divisor_q  <= divisor_magnitude;
              state_q    <= RUN;
            end
          end
        end

        RUN: begin
          quotient_q  <= quotient_next;
          remainder_q <= reduced_remainder;
          if (count_q == 5'd31) begin
            result_q <= corrected_result;
            state_q  <= DONE;
          end else begin
            count_q <= count_q + 5'd1;
          end
        end

        DONE: begin
          // Hold the result until EX has accepted it. This also handles a
          // completed divide waiting behind a stalled memory transaction.
          if (consume)
            state_q <= IDLE;
        end

        default: state_q <= IDLE;
      endcase
    end
  end

endmodule
