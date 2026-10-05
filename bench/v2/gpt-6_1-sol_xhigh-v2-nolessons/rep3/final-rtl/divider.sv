// Shared RV32M radix-2 restoring divider. Requests and results transfer
// only on valid && ready. Preparation, 32 iterations and sign correction
// occupy separate cycles; a completed result remains stable until consumed.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_signed,
  input  logic        req_rem,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        result_valid,
  input  logic        result_ready,
  output logic        result_rem,
  output logic [31:0] quotient,
  output logic [31:0] remainder
);
  localparam logic [2:0] IDLE = 3'd0, PREP = 3'd1, ITER = 3'd2,
                         CORRECT = 3'd3, DONE = 3'd4;
  logic [2:0] state_q;
  logic [31:0] divisor_q, quotient_q;
  // Bit 32 is retained for the restoring datapath; a restored remainder
  // is always less than the 32-bit divisor, so only its low bits shift in.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] remainder_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0] iteration_q;
  logic signed_q, quotient_neg_q, remainder_neg_q;
  logic [32:0] trial, difference;

  assign req_ready = (state_q == IDLE) && !reset;
  assign result_valid = (state_q == DONE) && !reset;
  assign trial = {remainder_q[31:0], quotient_q[31]};
  // Before each step remainder < divisor. The nonnegative difference
  // fits in 32 bits, so bit 32 is the borrow and also the quotient bit mux.
  assign difference = trial - {1'b0, divisor_q};

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q         <= IDLE;
      divisor_q       <= '0;
      quotient_q      <= '0;
      remainder_q     <= '0;
      iteration_q     <= '0;
      signed_q        <= 1'b0;
      quotient_neg_q  <= 1'b0;
      remainder_neg_q <= 1'b0;
      result_rem      <= 1'b0;
      quotient        <= '0;
      remainder       <= '0;
    end else begin
      case (state_q)
        IDLE: if (req_valid && req_ready) begin
          quotient_q      <= dividend;
          divisor_q       <= divisor;
          remainder_q     <= '0;
          iteration_q     <= '0;
          signed_q        <= req_signed;
          quotient_neg_q  <= req_signed && (dividend[31] ^ divisor[31]);
          remainder_neg_q <= req_signed && dividend[31];
          result_rem      <= req_rem;
          state_q         <= PREP;
        end
        PREP: begin
          if (divisor_q == 32'b0) begin
            quotient  <= 32'hffffffff;
            remainder <= quotient_q;
            state_q   <= DONE;
          end else if (signed_q && quotient_q == 32'h80000000 &&
                       divisor_q == 32'hffffffff) begin
            quotient  <= 32'h80000000;
            remainder <= 32'b0;
            state_q   <= DONE;
          end else begin
            quotient_q <= (signed_q && quotient_q[31])
                        ? -quotient_q : quotient_q;
            divisor_q  <= (signed_q && divisor_q[31])
                        ? -divisor_q : divisor_q;
            state_q    <= ITER;
          end
        end
        ITER: begin
          remainder_q <= difference[32] ? trial : difference;
          quotient_q  <= {quotient_q[30:0], !difference[32]};
          if (iteration_q == 5'd31) state_q <= CORRECT;
          else iteration_q <= iteration_q + 5'd1;
        end
        CORRECT: begin
          quotient  <= quotient_neg_q ? -quotient_q : quotient_q;
          remainder <= remainder_neg_q ? -remainder_q[31:0]
                                       : remainder_q[31:0];
          state_q   <= DONE;
        end
        DONE: if (result_ready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
