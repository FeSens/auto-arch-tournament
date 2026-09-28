// Shared RV32M divider. Each enabled work cycle resolves four quotient bits;
// the eighth work cycle presents the result for EX/MEM to capture.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        advance,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        ready,
  output logic        active,
  output logic [31:0] result,
  output logic [31:0] saved_a,
  output logic [31:0] saved_b
);
  logic        active_q;
  logic [2:0]  cycle_q;
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic [31:0] a_q, b_q;
  logic [4:0]  op_q;
  logic        quotient_negative_q, remainder_negative_q;
  logic [31:0] quotient_next, remainder_next;
  logic [32:0] trial;

  // This fixed four-step chain is the only divide datapath. The quotient
  // register initially holds the normalized dividend and doubles as the
  // source of the next dividend bit during restoring division.
  always_comb begin
    quotient_next  = quotient_q;
    remainder_next = remainder_q;
    trial = '0;
    for (int i = 0; i < 4; i++) begin
      trial = {remainder_next, quotient_next[31]};
      if (trial >= {1'b0, divisor_q}) begin
        remainder_next = trial[31:0] - divisor_q;
        quotient_next = {quotient_next[30:0], 1'b1};
      end else begin
        remainder_next = trial[31:0];
        quotient_next = {quotient_next[30:0], 1'b0};
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      active_q <= 1'b0;
      cycle_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      divisor_q <= '0;
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
    end else if (start) begin
      active_q <= 1'b1;
      cycle_q <= '0;
      a_q <= a;
      b_q <= b;
      op_q <= op;
      quotient_q <= ((op == ALU_DIV || op == ALU_REM) && a[31]) ? -a : a;
      divisor_q <= ((op == ALU_DIV || op == ALU_REM) && b[31]) ? -b : b;
      remainder_q <= '0;
      quotient_negative_q <= (op == ALU_DIV) && (a[31] ^ b[31]);
      remainder_negative_q <= (op == ALU_REM) && a[31];
    end else if (active_q && advance) begin
      quotient_q <= quotient_next;
      remainder_q <= remainder_next;
      if (cycle_q == 3'd7)
        active_q <= 1'b0;
      else
        cycle_q <= cycle_q + 3'd1;
    end
  end

  assign ready = active_q && cycle_q == 3'd7;
  assign active = active_q;
  assign saved_a = a_q;
  assign saved_b = b_q;

  always_comb begin
`ifdef RISCV_FORMAL_ALTOPS
    case (op_q)
      ALU_DIV:  result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU: result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:  result = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU: result = (a_q - b_q) ^ 32'h3138d0e1;
      default:  result = '0;
    endcase
`else
    if (b_q == 32'b0) begin
      result = (op_q == ALU_DIV || op_q == ALU_DIVU) ? 32'hffff_ffff : a_q;
    end else if ((op_q == ALU_DIV || op_q == ALU_REM) &&
                 a_q == 32'h8000_0000 && b_q == 32'hffff_ffff) begin
      result = (op_q == ALU_DIV) ? 32'h8000_0000 : 32'b0;
    end else if (op_q == ALU_DIV || op_q == ALU_DIVU) begin
      result = quotient_negative_q ? -quotient_next : quotient_next;
    end else begin
      result = remainder_negative_q ? -remainder_next : remainder_next;
    end
`endif
  end
endmodule
