// rtl/iter_divider.sv
//
// Small restoring divider for RV32M DIV/DIVU/REM/REMU. The datapath is one
// subtract/compare step per cycle, with RV32M special cases short-circuited
// before the iterative loop.
//
// Contract:
//   - Assert start for one cycle while the unit is idle.
//   - valid stays high with result stable until consume is asserted.
//   - start is ignored unless the unit is idle.
//
// Latency:        1 cycle for special cases, 34 cycles for ordinary divides
//                 (start edge + 32 quotient bits + postprocess).
// RVFI fields:    none directly; ex_stage captures result into EX/MEM.
module iter_divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        valid,
  output logic [31:0] result
);

  typedef enum logic [1:0] {
    DIV_IDLE = 2'd0,
    DIV_RUN  = 2'd1,
    DIV_DONE = 2'd2,
    DIV_POST = 2'd3
  } div_state_t;

  div_state_t state_q;

  logic [31:0] dividend_q;
  logic [31:0] divisor_q;
  logic [31:0] rem_q;
  logic [30:0] quot_q;
  logic [5:0]  count_q;
  logic        want_rem_q;
  logic        negate_quot_q;
  logic        negate_rem_q;
  logic [31:0] raw_quot_q;
  logic [31:0] raw_rem_q;
  logic [31:0] result_q;

  logic        start_is_signed;
  logic        start_is_rem;
  logic        start_dividend_neg;
  logic        start_divisor_neg;
  logic [31:0] start_abs_a;
  logic [31:0] start_abs_b;
  logic        start_div_by_zero;
  logic        start_signed_overflow;
  logic [31:0] start_special_result;

  logic [32:0] step_rem_shift;
  logic [32:0] step_divisor_ext;
  logic        step_take_sub;
  logic [31:0] step_rem_sub;
  logic [31:0] step_rem_next;
  logic [31:0] step_quot_next;
  logic [31:0] step_dividend_next;
  logic [31:0] post_quot_signed;
  logic [31:0] post_rem_signed;
  logic [31:0] post_result;

  always_comb begin
    start_is_signed       = (op == ALU_DIV) || (op == ALU_REM);
    start_is_rem          = (op == ALU_REM) || (op == ALU_REMU);
    start_dividend_neg    = start_is_signed && a[31];
    start_divisor_neg     = start_is_signed && b[31];
    start_abs_a           = start_dividend_neg ? (~a + 32'd1) : a;
    start_abs_b           = start_divisor_neg  ? (~b + 32'd1) : b;
    start_div_by_zero     = (b == 32'b0);
    start_signed_overflow = start_is_signed
                         && (a == 32'h8000_0000)
                         && (b == 32'hFFFF_FFFF);

    start_special_result = 32'b0;
    if (start_div_by_zero) begin
      start_special_result = start_is_rem ? a : 32'hFFFF_FFFF;
    end else if (start_signed_overflow) begin
      start_special_result = start_is_rem ? 32'b0 : 32'h8000_0000;
    end

    step_rem_shift     = {rem_q[31:0], dividend_q[31]};
    step_divisor_ext   = {1'b0, divisor_q};
    step_take_sub      = (step_rem_shift >= step_divisor_ext);
    step_rem_sub       = step_rem_shift[31:0] - divisor_q;
    step_rem_next      = step_take_sub ? step_rem_sub : step_rem_shift[31:0];
    step_quot_next     = {quot_q, step_take_sub};
    step_dividend_next = {dividend_q[30:0], 1'b0};

    post_quot_signed = negate_quot_q ? (~raw_quot_q + 32'd1)
                                     : raw_quot_q;
    post_rem_signed  = negate_rem_q ? (~raw_rem_q + 32'd1)
                                    : raw_rem_q;
    post_result      = want_rem_q ? post_rem_signed : post_quot_signed;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q       <= DIV_IDLE;
      dividend_q    <= 32'b0;
      divisor_q     <= 32'b0;
      rem_q         <= 32'b0;
      quot_q        <= 31'b0;
      count_q       <= 6'b0;
      want_rem_q    <= 1'b0;
      negate_quot_q <= 1'b0;
      negate_rem_q  <= 1'b0;
      raw_quot_q    <= 32'b0;
      raw_rem_q     <= 32'b0;
      result_q      <= 32'b0;
    end else begin
      if (state_q == DIV_DONE && consume) begin
        state_q <= DIV_IDLE;
      end else if (state_q == DIV_IDLE && start) begin
        want_rem_q    <= start_is_rem;
        negate_quot_q <= start_is_signed && (a[31] ^ b[31]);
        negate_rem_q  <= start_is_signed && a[31];
        rem_q         <= 32'b0;
        quot_q        <= 31'b0;
        raw_quot_q    <= 32'b0;
        raw_rem_q     <= 32'b0;
        count_q       <= 6'b0;

        if (start_div_by_zero || start_signed_overflow) begin
          result_q  <= start_special_result;
          dividend_q <= 32'b0;
          divisor_q  <= 32'b0;
          state_q   <= DIV_DONE;
        end else begin
          dividend_q <= start_abs_a;
          divisor_q  <= start_abs_b;
          state_q    <= DIV_RUN;
        end
      end else if (state_q == DIV_RUN) begin
        dividend_q <= step_dividend_next;
        rem_q      <= step_rem_next;
        quot_q     <= step_quot_next[30:0];
        count_q    <= count_q + 6'd1;

        if (count_q == 6'd31) begin
          raw_quot_q <= step_quot_next;
          raw_rem_q  <= step_rem_next;
          state_q    <= DIV_POST;
        end
      end else if (state_q == DIV_POST) begin
        result_q <= post_result;
        state_q  <= DIV_DONE;
      end
    end
  end

  assign busy   = (state_q == DIV_RUN) || (state_q == DIV_POST);
  assign valid  = (state_q == DIV_DONE);
  assign result = result_q;

endmodule
