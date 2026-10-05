// Blocking RV32M radix-2 restoring divider. A request first captures raw
// operands, then normalizes them in a separate registered stage. Each of
// the next 32 clocks produces one quotient bit. Sign correction is also
// registered; completion stays stable until result_ready consumes it.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  localparam logic [2:0] IDLE = 3'd0, NORMALIZE = 3'd1,
                         ITERATE = 3'd2, CORRECT = 3'd3, DONE = 3'd4;
  logic [2:0] state_q;
  logic [31:0] a_q, b_q;
  logic signed_q, rem_q, quotient_neg_q, remainder_neg_q;
  logic [31:0] divisor_q, quotient_q;
  logic [32:0] remainder_q;
  logic [4:0] iteration_q;
  logic [31:0] result_q;
  logic [32:0] shifted_remainder, difference;
  logic [31:0] magnitude;
  logic negate_result;

  assign req_ready = !reset && (state_q == IDLE);
  assign busy = !reset && (state_q != IDLE);
  assign result_valid = !reset && (state_q == DONE);
  assign result = result_q;

  // remainder < divisor after every iteration. Thus the signed bit of
  // this 33-bit difference is the compare result, even when the shifted
  // remainder needs its 33rd bit. The compare and subtract share one adder.
  assign shifted_remainder = (remainder_q << 1) | {32'b0, quotient_q[31]};
  assign difference = shifted_remainder - {1'b0, divisor_q};
  assign magnitude = rem_q ? remainder_q[31:0] : quotient_q;
  assign negate_result = rem_q ? remainder_neg_q : quotient_neg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      a_q <= '0;
      b_q <= '0;
      signed_q <= 1'b0;
      rem_q <= 1'b0;
      quotient_neg_q <= 1'b0;
      remainder_neg_q <= 1'b0;
      divisor_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      iteration_q <= '0;
      result_q <= '0;
    end else begin
      case (state_q)
        IDLE: if (req_valid && req_ready) begin
          a_q <= a;
          b_q <= b;
          signed_q <= (op == ALU_DIV || op == ALU_REM);
          rem_q <= (op == ALU_REM || op == ALU_REMU);
          state_q <= NORMALIZE;
        end
        NORMALIZE: begin
          quotient_q <= (signed_q && a_q[31]) ? (32'b0 - a_q) : a_q;
          divisor_q <= (signed_q && b_q[31]) ? (32'b0 - b_q) : b_q;
          quotient_neg_q <= signed_q && (a_q[31] ^ b_q[31]);
          remainder_neg_q <= signed_q && a_q[31];
          remainder_q <= '0;
          iteration_q <= '0;
          if (b_q == 32'b0) begin
            result_q <= rem_q ? a_q : 32'hffffffff;
            state_q <= DONE;
          end else if (signed_q && a_q == 32'h80000000 && b_q == 32'hffffffff) begin
            result_q <= rem_q ? 32'b0 : 32'h80000000;
            state_q <= DONE;
          end else begin
            state_q <= ITERATE;
          end
        end
        ITERATE: begin
          remainder_q <= difference[32] ? shifted_remainder : difference;
          quotient_q <= {quotient_q[30:0], !difference[32]};
          iteration_q <= iteration_q + 5'd1;
          if (iteration_q == 5'd31) state_q <= CORRECT;
        end
        CORRECT: begin
          result_q <= negate_result ? (32'b0 - magnitude) : magnitude;
          state_q <= DONE;
        end
        DONE: if (result_valid && result_ready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
