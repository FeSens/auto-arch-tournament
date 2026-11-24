// rtl/alu.sv
//
// RV32I and multiply results are combinational. DIV/DIVU/REM/REMU share
// a restoring divider. EX holds op from launch through consume.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif

module alu #(
  parameter bit SPLIT_MULTIPLY = 1'b0
) (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [31:0] mul_a,
  input  logic [31:0] mul_b,
  input  logic        div_start,
  input  logic        div_consume,
  output logic        div_busy,
  output logic        div_valid,
  output logic [31:0] out,
  output logic [31:0] mul_result,
  output logic        mul_select,
  output logic [31:0] add_result,
  output logic [31:0] shift_result,
  output logic [31:0] div_result,
  output logic [31:0] other_result
);

  logic [4:0] shamt;
  logic [31:0] mul_lhs, mul_rhs;

  assign mul_lhs = SPLIT_MULTIPLY ? mul_a : a;
  assign mul_rhs = SPLIT_MULTIPLY ? mul_b : b;
  assign mul_select = op == ALU_MUL || op == ALU_MULH
                   || op == ALU_MULHSU || op == ALU_MULHU;

`ifdef RISCV_FORMAL_ALTOPS
  // Use the riscv-formal arithmetic substitutes on the same result lane.
  always_comb begin
    case (op)
      ALU_MUL:    mul_result = (mul_lhs + mul_rhs) ^ 32'h5876063e;
      ALU_MULH:   mul_result = (mul_lhs + mul_rhs) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_result = (mul_lhs + mul_rhs) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_result = (mul_lhs - mul_rhs) ^ 32'hecfbe137;
      default:    mul_result = '0;
    endcase
  end
`else
  logic signed [32:0] mul_lhs_ext, mul_rhs_ext;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] product;
  /* verilator lint_on UNUSEDSIGNAL */

  assign mul_lhs_ext = $signed({(op == ALU_MULH || op == ALU_MULHSU) && mul_lhs[31], mul_lhs});
  assign mul_rhs_ext = $signed({op == ALU_MULH && mul_rhs[31], mul_rhs});
  assign product = mul_lhs_ext * mul_rhs_ext;
  assign mul_result = op == ALU_MUL ? product[31:0] : product[63:32];
`endif

  // Phase 0 is idle. Phases 8 through 2 perform the seven updates.
  // Phase 1 holds the divider state until EX/MEM accepts the result.
  logic [3:0] div_phase_q;
  logic       div_launch;

  assign div_busy = div_phase_q != 4'd0;
  assign div_valid = div_phase_q == 4'd1;
  assign div_launch = div_start && !div_busy;

  always_ff @(posedge clock) begin
    if (reset)
      div_phase_q <= 4'd0;
    else if (div_launch)
      div_phase_q <= 4'd8;
    else if (div_busy && (!div_valid || div_consume))
      div_phase_q <= div_phase_q - 4'd1;
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Capture the formal substitute at launch and use the same handshake
  // and completion schedule as the hardware divider.
  always_ff @(posedge clock) begin
    if (div_launch) begin
      case (op)
        ALU_DIV:  div_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_result <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: div_result <= (a - b) ^ 32'h3138d0e1;
        default:  div_result <= '0;
      endcase
    end
  end
`else
  logic        signed_div, select_rem, neg_a, neg_b;
  logic        select_rem_q, negate_q;
  logic [31:0] divisor_q, magnitude;
  logic [33:0] triple_divisor_q;
  logic [7:0] prefix_triple;
  logic [3:0] prefix_2;
  logic [5:0] prefix_4;
  logic [7:0] prefix_6;
  // Upper half is the partial remainder. The lower half shifts out
  // the dividend bits and shifts in the quotient bits.
  logic [63:0] partial_q, after_prefix, after_radix4_a, after_radix4_b;

  function automatic [3:0] first_step(
    input logic [1:0] leading,
    input logic [5:0] divisor
  );
    logic [1:0] digit, remainder;
    begin
      // The initial remainder is zero, so only divisors up to three
      // can produce a nonzero digit in the first two bits.
      digit = 2'd0;
      remainder = leading;
      case ({|divisor[5:2], divisor[1:0]})
        3'd0: digit = 2'd3;
        3'd1: begin
          digit = leading;
          remainder = 2'd0;
        end
        3'd2: begin
          digit = {1'b0, leading[1]};
          remainder = {1'b0, leading[0]};
        end
        3'd3: begin
          digit = {1'b0, &leading};
          remainder = (&leading) ? 2'd0 : leading;
        end
        default: ;
      endcase
      first_step = {remainder, digit};
    end
  endfunction

  // During the first update, each shifted remainder fits in six bits.
  // Larger divisors bypass this calculation at after_prefix.
  function automatic [7:0] prefix_step(
    input logic [5:0] shifted,
    input logic [5:0] divisor,
    input logic [7:0] triple_divisor
  );
    /* verilator lint_off UNUSEDSIGNAL */
    logic [8:0] trial_one, trial_two, trial_three;
    /* verilator lint_on UNUSEDSIGNAL */
    logic select_zero, select_one, select_two, select_three;
    logic [5:0] remainder;
    logic [1:0] digit;
    begin
      trial_one   = {3'b0, shifted} - {3'b0, divisor};
      trial_two   = {3'b0, shifted} - {2'b0, divisor, 1'b0};
      trial_three = {3'b0, shifted} - {1'b0, triple_divisor};
      select_zero  = trial_one[8];
      select_one   = !trial_one[8] && trial_two[8];
      select_two   = !trial_two[8] && trial_three[8];
      select_three = !trial_three[8];
      remainder = ({6{select_zero}}  & shifted)
                | ({6{select_one}}   & trial_one[5:0])
                | ({6{select_two}}   & trial_two[5:0])
                | ({6{select_three}} & trial_three[5:0]);
      digit = {select_two || select_three, select_one || select_three};
      prefix_step = {remainder, digit};
    end
  endfunction

  function automatic [63:0] radix4_step(
    input logic [63:0] partial,
    input logic [31:0] divisor,
    input logic [33:0] triple_divisor
  );
    logic [34:0] shifted;
    // Only the borrow and the low 32 bits of each trial are used.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [34:0] trial_one, trial_two, trial_three;
    /* verilator lint_on UNUSEDSIGNAL */
    logic select_zero, select_one, select_two, select_three;
    logic [31:0] remainder;
    logic [1:0] digit;
    begin
      shifted = {1'b0, partial[63:30]};
      trial_one   = shifted - {3'b0, divisor};
      trial_two   = shifted - {2'b0, divisor, 1'b0};
      trial_three = shifted - {1'b0, triple_divisor};

      // The ordered trials select the largest digit without a borrow.
      select_zero  = trial_one[34];
      select_one   = !trial_one[34] && trial_two[34];
      select_two   = !trial_two[34] && trial_three[34];
      select_three = !trial_three[34];
      remainder = ({32{select_zero}}  & shifted[31:0])
                | ({32{select_one}}   & trial_one[31:0])
                | ({32{select_two}}   & trial_two[31:0])
                | ({32{select_three}} & trial_three[31:0]);
      digit = {select_two || select_three, select_one || select_three};
      radix4_step = {remainder, partial[29:0], digit};
    end
  endfunction

  assign signed_div = op == ALU_DIV || op == ALU_REM;
  assign select_rem = op == ALU_REM || op == ALU_REMU;
  assign neg_a = signed_div && a[31];
  assign neg_b = signed_div && b[31];

  // Process six quotient bits on the first update and four per update
  // for the remaining six updates. The final digit resolves in phase 1.
  assign prefix_triple = {2'b0, divisor_q[5:0]} + {1'b0, divisor_q[5:0], 1'b0};
  assign prefix_2 = first_step(partial_q[31:30], divisor_q[5:0]);
  assign prefix_4 = 6'(prefix_step({2'b0, prefix_2[3:2], partial_q[29:28]},
                                  divisor_q[5:0], prefix_triple));
  assign prefix_6 = prefix_step({prefix_4[5:2], partial_q[27:26]}, divisor_q[5:0], prefix_triple);
  assign after_prefix = (|divisor_q[31:6])
                      ? {26'b0, partial_q[31:26], partial_q[25:0], 6'b0}
                      : {26'b0, prefix_6[7:2], partial_q[25:0],
                         prefix_2[1:0], prefix_4[1:0], prefix_6[1:0]};
  assign after_radix4_a = radix4_step(partial_q, divisor_q, triple_divisor_q);
  assign after_radix4_b = radix4_step(after_radix4_a, divisor_q, triple_divisor_q);

  always_ff @(posedge clock) begin
    if (div_launch) begin
      partial_q    <= {32'b0, neg_a ? -a : a};
      divisor_q    <= neg_b ? -b : b;
      select_rem_q <= select_rem;
      // With a zero divisor, every trial succeeds. The quotient is
      // all ones and the remainder is the dividend magnitude.
      negate_q     <= select_rem ? neg_a : ((neg_a ^ neg_b) && b != 32'b0);
    end else if (div_phase_q == 4'd8) begin
      partial_q        <= after_prefix;
      triple_divisor_q <= {2'b0, divisor_q} + {1'b0, divisor_q, 1'b0};
    end else if (div_busy && !div_valid) begin
      partial_q <= after_radix4_b;
    end
  end

  // Reuse the first radix-4 step for the final digit while phase 1 holds
  // its inputs stable. The unsigned magnitude of INT_MIN fits in 32 bits,
  // so dividing by one gives the INT_MIN bit pattern and zero remainder.
  assign magnitude  = select_rem_q ? after_radix4_a[63:32] : after_radix4_a[31:0];
  assign div_result = negate_q ? -magnitude : magnitude;
`endif

  assign add_result = op == ALU_SUB ? a - b : a + b;
  assign shamt = b[4:0];

  always_comb begin
    case (op)
      ALU_SLL:    shift_result = a << shamt;
      ALU_SRA:    shift_result = $unsigned($signed(a) >>> shamt);
      default:    shift_result = a >> shamt;
    endcase
  end

  always_comb begin
    case (op)
      ALU_AND:    other_result = a & b;
      ALU_OR:     other_result = a | b;
      ALU_XOR:    other_result = a ^ b;
      ALU_SLT:    other_result = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   other_result = {31'b0, a < b};
      ALU_LUI:    other_result = b;
      default:    other_result = 32'b0;
    endcase
  end

  // Standalone ALU interface. The core consumes the individual result lanes.
  always_comb begin
    case (op)
      ALU_ADD, ALU_SUB: out = add_result;
      ALU_SLL, ALU_SRL, ALU_SRA: out = shift_result;
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU:
        out = SPLIT_MULTIPLY ? 32'b0 : mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default: out = other_result;
    endcase
  end

endmodule
