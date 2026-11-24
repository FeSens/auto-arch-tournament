// One unsigned division path. Each RUN edge consumes DIGITS pairs of
// dividend bits, replacing them in the shift register with quotient digits.
module radix4_path #(
  parameter int REM_BITS = 32,
  parameter int DIGITS = 2,
  localparam int SHIFT_BITS = 6 * 2 * DIGITS,
  localparam int QUOT_BITS = SHIFT_BITS > 32 ? 32 : SHIFT_BITS
) (
  input  logic                  clock,
  input  logic                  start,
  input  logic                  prep,
  input  logic                  run,
  input  logic [REM_BITS-1:0]   divisor,
  input  logic [REM_BITS-1:0]   initial_remainder,
  input  logic [SHIFT_BITS-1:0] dividend_bits,
  output logic [REM_BITS-1:0]   remainder,
  output logic [QUOT_BITS-1:0]  quotient
);
  logic [SHIFT_BITS-1:0] shift_q, shift_next;
  logic [REM_BITS-1:0] rem_next;
  logic [REM_BITS+1:0] one_d, two_d, three_d_q, trial;
  // The extra bit records borrow. The selected residue fits in REM_BITS.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [REM_BITS+2:0] diff1, diff2, diff3;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0] digit;

  assign one_d = {2'b00, divisor};
  assign two_d = {1'b0, divisor, 1'b0};

  always_comb begin
    shift_next = shift_q;
    rem_next = remainder;
    for (int i = 0; i < DIGITS; i++) begin
      trial = {rem_next, shift_next[SHIFT_BITS-1 -: 2]};
      diff1 = {1'b0, trial} - {1'b0, one_d};
      diff2 = {1'b0, trial} - {1'b0, two_d};
      diff3 = {1'b0, trial} - {1'b0, three_d_q};
      if (diff2[REM_BITS+2]) begin
        digit = {1'b0, !diff1[REM_BITS+2]};
        rem_next = diff1[REM_BITS+2] ? trial[REM_BITS-1:0] : diff1[REM_BITS-1:0];
      end else begin
        digit = {1'b1, !diff3[REM_BITS+2]};
        rem_next = diff3[REM_BITS+2] ? diff2[REM_BITS-1:0] : diff3[REM_BITS-1:0];
      end
      shift_next = {shift_next[SHIFT_BITS-3:0], digit};
    end
  end

  always_ff @(posedge clock) begin
    if (prep) three_d_q <= one_d + two_d;
    if (start) begin
      shift_q   <= dividend_bits;
      remainder <= initial_remainder;
    end else if (run) begin
      shift_q   <= shift_next;
      remainder <= rem_next;
    end
  end

  assign quotient = shift_q[QUOT_BITS-1:0];
endmodule
