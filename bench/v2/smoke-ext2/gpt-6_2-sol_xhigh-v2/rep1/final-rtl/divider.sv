// One RV32M divide or remainder at a time: launch, six radix-4 cycles,
// then hold the result until EX/MEM accepts it.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        idle,
  output logic        result_valid,
  output logic [31:0] result
);
  logic [2:0] step_q;

  assign idle = (step_q == 3'd0);
  assign result_valid = (step_q == 3'd7);

  always_ff @(posedge clock) begin
    if (reset)
      step_q <= 3'd0;
    else if (idle) begin
      if (start) step_q <= 3'd1;
    end else if (result_valid) begin
      if (accept) step_q <= 3'd0;
    end else begin
      step_q <= step_q + 3'd1;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_mask;
  logic [31:0] alt_result_q;

  always_comb begin
    case (op)
      ALU_DIV:  alt_mask = 32'h7f8529ec;
      ALU_DIVU: alt_mask = 32'h10e8fd70;
      ALU_REM:  alt_mask = 32'h8da68fa5;
      ALU_REMU: alt_mask = 32'h3138d0e1;
      default:  alt_mask = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset)
      alt_result_q <= 32'b0;
    else if (idle && start)
      alt_result_q <= (a - b) ^ alt_mask;
  end

  assign result = alt_result_q;
`else
  logic signed_op, select_rem, a_negative, b_negative;
  logic [31:0] a_mag, b_mag;
  logic        select_rem_q, negate_q;
  logic [33:0] divisor_q, twice_q, triple_q;
  logic [31:0] rem_q;
  logic [35:0] dividend_quotient_q;
  logic [31:0] magnitude;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign select_rem = (op == ALU_REM || op == ALU_REMU);
  assign a_negative = signed_op && a[31];
  assign b_negative = signed_op && b[31];
  assign a_mag = a_negative ? -a : a;
  assign b_mag = b_negative ? -b : b;

  // Each step forms three trial differences in parallel. The extra MSB
  // records borrow. Since D <= 2D <= 3D, adjacent borrow bits select
  // exactly one trial (or preserve the shifted remainder for digit zero).
  function automatic [33:0] radix4_digit (
    input logic [33:0] shifted,
    input logic [33:0] divisor,
    input logic [33:0] twice,
    input logic [33:0] triple
  );
    // The selected difference fits in 32 bits: it is less than D for
    // D != 0, or the processed prefix of the dividend for D == 0.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] trial1, trial2, trial3;
    /* verilator lint_on UNUSEDSIGNAL */
    logic take0, take1, take2, take3;
    logic [31:0] remainder;

    trial1 = {1'b0, shifted} - {1'b0, divisor};
    trial2 = {1'b0, shifted} - {1'b0, twice};
    trial3 = {1'b0, shifted} - {1'b0, triple};
    take0 = trial1[34];
    take1 = trial2[34] && !trial1[34];
    take2 = trial3[34] && !trial2[34];
    take3 = !trial3[34];
    remainder = ({32{take0}} & shifted[31:0])
              | ({32{take1}} & trial1[31:0])
              | ({32{take2}} & trial2[31:0])
              | ({32{take3}} & trial3[31:0]);
    radix4_digit = {remainder, (take2 | take3), (take1 | take3)};
  endfunction

  logic [31:0] rem1, rem2, rem3;
  logic [1:0] digit1, digit2, digit3;

  assign {rem1, digit1} = radix4_digit({rem_q, dividend_quotient_q[35:34]},
                                      divisor_q, twice_q, triple_q);
  assign {rem2, digit2} = radix4_digit({rem1, dividend_quotient_q[33:32]},
                                      divisor_q, twice_q, triple_q);
  assign {rem3, digit3} = radix4_digit({rem2, dividend_quotient_q[31:30]},
                                      divisor_q, twice_q, triple_q);

  always_ff @(posedge clock) begin
    if (reset) begin
      divisor_q           <= '0;
      twice_q             <= '0;
      triple_q            <= '0;
      rem_q               <= '0;
      dividend_quotient_q <= '0;
      select_rem_q        <= 1'b0;
      negate_q            <= 1'b0;
    end else if (idle && start) begin
      divisor_q           <= {2'b0, b_mag};
      twice_q             <= {1'b0, b_mag, 1'b0};
      triple_q            <= {2'b0, b_mag} + {1'b0, b_mag, 1'b0};
      rem_q               <= '0;
      dividend_quotient_q <= {4'b0, a_mag};
      select_rem_q        <= select_rem;
      // When D is zero every quotient digit is 3, and the remainder is
      // the dividend magnitude. Leave the all-ones quotient as-is.
      negate_q <= select_rem ? a_negative : (a_negative ^ b_negative) && (b != 32'b0);
    end else if (!idle && !result_valid) begin
      rem_q               <= rem3;
      dividend_quotient_q <= {dividend_quotient_q[29:0], digit1, digit2, digit3};
    end
  end

  // Taking the low 32 quotient bits also naturally gives INT_MIN for
  // the signed overflow case INT_MIN / -1, with remainder zero.
  assign magnitude = select_rem_q ? rem_q : dividend_quotient_q[31:0];
  assign result = negate_q ? -magnitude : magnitude;
`endif
endmodule
