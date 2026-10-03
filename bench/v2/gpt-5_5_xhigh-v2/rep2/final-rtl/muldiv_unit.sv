// rtl/muldiv_unit.sv
//
// Sequential RV32M unit. MUL/MULH/MULHSU/MULHU complete through a registered
// product path; DIV/REM operations use a one-bit-per-cycle restoring divider.
// RISCV_FORMAL_ALTOPS replaces every M operation with the same lightweight
// formulas used by riscv-formal so the fast BMC remains inside its depth.
module muldiv_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] MD_IDLE = 2'd0;
  localparam logic [1:0] MD_DIV  = 2'd1;
  localparam logic [1:0] MD_DONE = 2'd2;

  logic [1:0]  state_q;
  logic [31:0] result_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;

  always_comb begin
    case (op)
      ALU_MUL:    alt_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   alt_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_result = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    alt_result = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   alt_result = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    alt_result = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   alt_result = (a - b) ^ 32'h3138d0e1;
      default:    alt_result = 32'b0;
    endcase
  end
`else
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;
  logic        [63:0] mul_uu;
  logic signed [63:0] mul_su;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0]        mul_result;

  logic        is_mul_op;
  logic        is_div_op;
  logic        signed_div_op;
  logic        rem_op;
  logic        div_zero;
  logic        div_overflow;
  logic [31:0] a_abs;
  logic [31:0] b_abs;
  logic [31:0] special_result;

  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] quotient_q;
  logic [32:0] remainder_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0]  count_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;
  logic        result_is_rem_q;

  logic [32:0] trial_remainder;
  logic [32:0] divisor_ext;
  logic [32:0] next_remainder;
  logic [31:0] next_quotient;
  logic [31:0] next_dividend;
  logic [31:0] signed_quotient;
  logic [31:0] signed_remainder;

  always_comb begin
    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

    case (op)
      ALU_MUL:    mul_result = mul_uu[31:0];
      ALU_MULH:   mul_result = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  mul_result = mul_uu[63:32];
      ALU_MULHSU: mul_result = $unsigned(mul_su[63:32]);
      default:    mul_result = 32'b0;
    endcase

    is_mul_op     = (op == ALU_MUL)  || (op == ALU_MULH) ||
                    (op == ALU_MULHU) || (op == ALU_MULHSU);
    is_div_op     = (op == ALU_DIV)  || (op == ALU_DIVU) ||
                    (op == ALU_REM)  || (op == ALU_REMU);
    signed_div_op = (op == ALU_DIV)  || (op == ALU_REM);
    rem_op        = (op == ALU_REM)  || (op == ALU_REMU);
    div_zero      = (b == 32'b0);
    div_overflow  = signed_div_op && (a == 32'h80000000) && (b == 32'hFFFFFFFF);

    a_abs = (signed_div_op && a[31]) ? (~a + 32'd1) : a;
    b_abs = (signed_div_op && b[31]) ? (~b + 32'd1) : b;

    if (div_zero)
      special_result = rem_op ? a : 32'hFFFFFFFF;
    else if (div_overflow)
      special_result = rem_op ? 32'b0 : 32'h80000000;
    else
      special_result = 32'b0;

    trial_remainder = {remainder_q[31:0], dividend_q[31]};
    divisor_ext     = {1'b0, divisor_q};
    next_dividend   = {dividend_q[30:0], 1'b0};
    if (trial_remainder >= divisor_ext) begin
      next_remainder = trial_remainder - divisor_ext;
      next_quotient  = {quotient_q[30:0], 1'b1};
    end else begin
      next_remainder = trial_remainder;
      next_quotient  = {quotient_q[30:0], 1'b0};
    end

    signed_quotient  = quotient_neg_q  ? (~next_quotient + 32'd1)
                                       : next_quotient;
    signed_remainder = remainder_neg_q ? (~next_remainder[31:0] + 32'd1)
                                       : next_remainder[31:0];
  end
`endif

  assign busy   = (state_q != MD_IDLE);
  assign done   = (state_q == MD_DONE);
  assign result = result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= MD_IDLE;
      result_q <= 32'b0;
`ifndef RISCV_FORMAL_ALTOPS
      dividend_q <= 32'b0;
      divisor_q <= 32'b0;
      quotient_q <= 32'b0;
      remainder_q <= 33'b0;
      count_q <= 6'b0;
      quotient_neg_q <= 1'b0;
      remainder_neg_q <= 1'b0;
      result_is_rem_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        MD_IDLE: begin
          if (start) begin
`ifdef RISCV_FORMAL_ALTOPS
            result_q <= alt_result;
            state_q  <= MD_DONE;
`else
            if (is_mul_op) begin
              result_q <= mul_result;
              state_q  <= MD_DONE;
            end else if (is_div_op) begin
              if (div_zero || div_overflow) begin
                result_q <= special_result;
                state_q  <= MD_DONE;
              end else begin
                dividend_q      <= a_abs;
                divisor_q       <= b_abs;
                quotient_q      <= 32'b0;
                remainder_q     <= 33'b0;
                count_q         <= 6'd32;
                quotient_neg_q  <= signed_div_op && (a[31] ^ b[31]);
                remainder_neg_q <= signed_div_op && a[31];
                result_is_rem_q <= rem_op;
                state_q         <= MD_DIV;
              end
            end else begin
              result_q <= 32'b0;
              state_q  <= MD_DONE;
            end
`endif
          end
        end

`ifndef RISCV_FORMAL_ALTOPS
        MD_DIV: begin
          dividend_q  <= next_dividend;
          quotient_q  <= next_quotient;
          remainder_q <= next_remainder;
          if (count_q == 6'd1) begin
            result_q <= result_is_rem_q ? signed_remainder : signed_quotient;
            count_q  <= 6'b0;
            state_q  <= MD_DONE;
          end else begin
            count_q <= count_q - 6'd1;
          end
        end
`endif

        MD_DONE: begin
          state_q <= MD_IDLE;
        end

        default: begin
          state_q <= MD_IDLE;
        end
      endcase
    end
  end

endmodule
