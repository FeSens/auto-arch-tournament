// Shared RV32M radix-4 restoring divider. One launch, 16 iterations, one
// held result; consume acknowledges the result at the EX/MEM capture edge.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  logic active_q, done_q;
  logic [3:0] count_q;
  logic [31:0] divisor_q;
  logic [31:0] quotient_q;
  logic [31:0] remainder_q;
  logic neg_quotient_q, neg_remainder_q, is_remainder_q, zero_divisor_q;
  logic [31:0] original_a_q, result_q;

  logic [33:0] trial, d1, d2, d3;
  logic [31:0] chosen, remainder_next;
  logic [1:0] digit;
  logic [31:0] quotient_next, signed_quotient, signed_remainder;

  always_comb begin
    trial = {remainder_q, quotient_q[31:30]};
    d1 = {2'b00, divisor_q};
    d2 = {1'b0, divisor_q, 1'b0};
    d3 = d1 + d2;
    if (trial >= d3) begin
      digit = 2'd3;
      chosen = d3[31:0];
    end else if (trial >= d2) begin
      digit = 2'd2;
      chosen = d2[31:0];
    end else if (trial >= d1) begin
      digit = 2'd1;
      chosen = d1[31:0];
    end else begin
      digit = 2'd0;
      chosen = 32'b0;
    end
    remainder_next = trial[31:0] - chosen;
    quotient_next = {quotient_q[29:0], digit};
    signed_quotient = neg_quotient_q ? -quotient_next : quotient_next;
    signed_remainder = neg_remainder_q ? -remainder_next : remainder_next;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      active_q <= 1'b0;
      done_q <= 1'b0;
      count_q <= '0;
      divisor_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      neg_quotient_q <= 1'b0;
      neg_remainder_q <= 1'b0;
      is_remainder_q <= 1'b0;
      zero_divisor_q <= 1'b0;
      original_a_q <= '0;
      result_q <= '0;
    end else if (consume && done_q) begin
      done_q <= 1'b0;
    end else if (start && !active_q && !done_q) begin
      active_q <= 1'b1;
      count_q <= 4'd0;
      divisor_q <= ((op == ALU_DIV || op == ALU_REM) && b[31]) ? -b : b;
      quotient_q <= ((op == ALU_DIV || op == ALU_REM) && a[31]) ? -a : a;
      remainder_q <= '0;
      neg_quotient_q <= (op == ALU_DIV || op == ALU_REM) && (a[31] ^ b[31]);
      neg_remainder_q <= (op == ALU_DIV || op == ALU_REM) && a[31];
      is_remainder_q <= (op == ALU_REM || op == ALU_REMU);
      zero_divisor_q <= (b == 32'b0);
      original_a_q <= a;
    end else if (active_q) begin
      quotient_q <= quotient_next;
      remainder_q <= remainder_next;
      count_q <= count_q + 4'd1;
      if (count_q == 4'd15) begin
        active_q <= 1'b0;
        done_q <= 1'b1;
        result_q <= zero_divisor_q
                    ? (is_remainder_q ? original_a_q : 32'hffff_ffff)
                    : (is_remainder_q ? signed_remainder : signed_quotient);
      end
    end
  end

  assign busy = active_q || done_q;
  assign done = done_q;
  assign result = result_q;

endmodule
