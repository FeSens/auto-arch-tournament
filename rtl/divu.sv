// rtl/divu.sv
//
// Multi-cycle iterative unsigned 32x32 -> 32 divider. Implements a
// classical restoring binary division: a 33-bit partial remainder, a
// 32-bit quotient shifter, and a 32-bit divisor latch. Each iteration:
//   - shift {rem, quot} left by 1 (the MSB of quot moves into rem's LSB)
//   - trial-subtract divisor from rem
//   - if non-negative, take the subtraction and set quot LSB
//   - otherwise keep the shifted rem and clear quot LSB
//
// Sign handling and RV32M edge cases (b == 0; INT_MIN / -1) are NOT
// done here — they are the caller's (alu.sv) responsibility. divu is
// pure unsigned arithmetic.
//
// Latency:        33 cycles from `start` rising to `done` rising:
//                   1 cycle in IDLE accepting the start pulse,
//                   32 cycles in BUSY iterating,
//                   1 cycle in DONE asserting `done`.
//                 The result remains valid in the quot/rem registers
//                 across IDLE/DONE — the caller may capture it any
//                 cycle after `done` was asserted, until the next
//                 `start` clobbers the operand latches.
// RVFI fields:    none. divu is internal arithmetic; alu.sv routes the
//                 sign-corrected result to rd_wdata via EX/MEM/WB.
module divu (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic [31:0] quotient,
  output logic [31:0] remainder,
  output logic        busy,
  output logic        done
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_BUSY = 2'd1;
  localparam logic [1:0] S_DONE = 2'd2;

  logic [1:0]  state;
  logic [5:0]  iter;
  // Post-iteration partial remainder. Always < divisor <= 2^32 - 1
  // between iterations, so 32 bits are sufficient. The 33rd bit needed
  // for the shift-and-trial-subtract is reconstructed combinationally
  // each cycle (rem_shifted / sub_result below).
  logic [31:0] rem_q;
  logic [31:0] quot_q;
  logic [31:0] divisor_q;

  // Combinational shift-subtract used in S_BUSY.
  logic [32:0] rem_shifted;
  logic [32:0] sub_result;
  logic        sub_neg;

  always_comb begin
    // Shift {rem, quot} left by 1 — the MSB of quot moves into rem[0].
    // The 33rd bit can be set if 2*rem >= 2^32, but that only happens
    // when sub_neg will be 0 (subtraction takes precedence and yields a
    // value < divisor < 2^32). On the sub_neg=1 path, rem_shifted is
    // strictly < divisor < 2^32, so its bit 32 is 0 and rem_shifted[31:0]
    // is the full post-iteration remainder.
    rem_shifted = {rem_q, quot_q[31]};
    sub_result  = rem_shifted - {1'b0, divisor_q};
    sub_neg     = sub_result[32];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state     <= S_IDLE;
      iter      <= 6'd0;
      rem_q     <= 32'd0;
      quot_q    <= 32'd0;
      divisor_q <= 32'd0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            state     <= S_BUSY;
            iter      <= 6'd0;
            rem_q     <= 32'd0;
            quot_q    <= dividend;
            divisor_q <= divisor;
          end
        end
        S_BUSY: begin
          rem_q  <= sub_neg ? rem_shifted[31:0] : sub_result[31:0];
          quot_q <= {quot_q[30:0], ~sub_neg};
          iter   <= iter + 6'd1;
          if (iter == 6'd31) state <= S_DONE;
        end
        S_DONE: begin
          state <= S_IDLE;
        end
        default: begin
          state <= S_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    quotient  = quot_q;
    remainder = rem_q;
    // busy is high from the cycle `start` is asserted (combinationally)
    // through the DONE state. The IDLE-with-start case is folded in so
    // a caller polling `busy` sees 1 on cycle 0 of the divide.
    busy      = (state != S_IDLE) || start;
    done      = (state == S_DONE);
  end

endmodule
