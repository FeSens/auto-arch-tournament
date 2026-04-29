// rtl/div_unit.sv
//
// Iterative RV32M divider/remainder unit. The EX stage starts it only for
// DIV/DIVU/REM/REMU and bubbles EX/MEM until done, keeping the cold divider
// off the one-cycle ALU result path.
module div_unit (
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

  localparam logic [1:0] ST_IDLE = 2'd0;
  localparam logic [1:0] ST_BUSY = 2'd1;
  localparam logic [1:0] ST_DONE = 2'd2;

  logic [1:0]  state_q;
  logic [31:0] result_q;

  assign busy   = (state_q == ST_BUSY);
  assign done   = (state_q == ST_DONE);
  assign result = result_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;

  always_comb begin
    case (op)
      ALU_DIV:  alt_result = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: alt_result = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  alt_result = (a - b) ^ 32'h8da68fa5;
      ALU_REMU: alt_result = (a - b) ^ 32'h3138d0e1;
      default:  alt_result = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q  <= ST_IDLE;
      result_q <= 32'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start) begin
            result_q <= alt_result;
            state_q  <= ST_BUSY;
          end
        end
        ST_BUSY: state_q <= ST_DONE;
        ST_DONE: state_q <= ST_IDLE;
        default: state_q <= ST_IDLE;
      endcase
    end
  end
`else
  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] quotient_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] remainder_q;
  logic [5:0]  count_q;
  logic        quot_neg_q;
  logic        rem_neg_q;
  logic        want_rem_q;

  logic        signed_op;
  logic        want_rem;
  logic        a_neg;
  logic        b_neg;
  logic [31:0] abs_a;
  logic [31:0] abs_b;
  logic        divide_by_zero;
  logic        signed_overflow;
  logic [31:0] special_result;

  logic [32:0] trial_remainder;
  logic [32:0] trial_divisor;
  logic        trial_take;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] remainder_step;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] quotient_step;
  logic [31:0] unsigned_remainder;
  logic [31:0] signed_quotient;
  logic [31:0] signed_remainder;
  logic [31:0] final_result;

  always_comb begin
    signed_op       = (op == ALU_DIV) || (op == ALU_REM);
    want_rem        = (op == ALU_REM) || (op == ALU_REMU);
    a_neg           = signed_op && a[31];
    b_neg           = signed_op && b[31];
    abs_a           = a_neg ? (~a + 32'd1) : a;
    abs_b           = b_neg ? (~b + 32'd1) : b;
    divide_by_zero  = (b == 32'b0);
    signed_overflow = signed_op && (a == 32'h80000000) && (b == 32'hFFFFFFFF);

    if (divide_by_zero)
      special_result = want_rem ? a : 32'hFFFFFFFF;
    else if (signed_overflow)
      special_result = want_rem ? 32'b0 : 32'h80000000;
    else
      special_result = 32'b0;

    trial_remainder   = {remainder_q, dividend_q[31]};
    trial_divisor     = {1'b0, divisor_q};
    trial_take        = (trial_remainder >= trial_divisor);
    remainder_step    = trial_take ? (trial_remainder - trial_divisor)
                                   : trial_remainder;
    quotient_step     = {quotient_q[30:0], trial_take};
    unsigned_remainder = remainder_step[31:0];
    signed_quotient   = quot_neg_q ? (~quotient_step + 32'd1)
                                   : quotient_step;
    signed_remainder  = rem_neg_q ? (~unsigned_remainder + 32'd1)
                                  : unsigned_remainder;
    final_result      = want_rem_q ? signed_remainder : signed_quotient;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q     <= ST_IDLE;
      result_q    <= 32'b0;
      dividend_q  <= 32'b0;
      divisor_q   <= 32'b0;
      quotient_q  <= 32'b0;
      remainder_q <= 32'b0;
      count_q     <= 6'b0;
      quot_neg_q  <= 1'b0;
      rem_neg_q   <= 1'b0;
      want_rem_q  <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start) begin
            quotient_q  <= 32'b0;
            remainder_q <= 32'b0;
            want_rem_q  <= want_rem;
            quot_neg_q  <= signed_op && (a[31] ^ b[31]);
            rem_neg_q   <= signed_op && a[31];
            if (divide_by_zero || signed_overflow) begin
              result_q   <= special_result;
              dividend_q <= 32'b0;
              divisor_q  <= 32'b0;
              count_q    <= 6'b0;
            end else begin
              dividend_q <= abs_a;
              divisor_q  <= abs_b;
              count_q    <= 6'd32;
            end
            state_q <= ST_BUSY;
          end
        end

        ST_BUSY: begin
          if (count_q == 6'b0) begin
            state_q <= ST_DONE;
          end else begin
            dividend_q  <= {dividend_q[30:0], 1'b0};
            quotient_q  <= quotient_step;
            remainder_q <= remainder_step[31:0];
            count_q     <= count_q - 6'd1;
            if (count_q == 6'd1) begin
              result_q <= final_result;
              state_q  <= ST_DONE;
            end
          end
        end

        ST_DONE: state_q <= ST_IDLE;
        default: state_q <= ST_IDLE;
      endcase
    end
  end
`endif

endmodule
