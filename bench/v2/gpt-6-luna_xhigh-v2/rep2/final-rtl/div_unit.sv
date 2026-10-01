// Shared radix-2 restoring divider for RV32M DIV/DIVU/REM/REMU.
// start captures the request; done stays asserted until consume.  Keeping
// done level-sensitive lets EX wait behind a stalled older memory op.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] DIV_IDLE = 2'd0;
  localparam logic [1:0] DIV_RUN  = 2'd1;
  localparam logic [1:0] DIV_DONE = 2'd2;

  logic [1:0] state_q;
  logic [5:0] count_q;
  logic [31:0] quotient_q;
  logic [31:0] divisor_q;
  logic [31:0] remainder_q;
  logic        quotient_op_q;
  logic        neg_quotient_q;
  logic        neg_remainder_q;

  logic [31:0] abs_dividend;
  logic [31:0] abs_divisor;
  logic [32:0] remainder_shifted;
  logic [31:0] remainder_next;
  logic [31:0] quotient_next;
  logic [31:0] quotient_final;
  logic [31:0] remainder_final;

  always_comb begin
    abs_dividend = dividend;
    abs_divisor = divisor;
    if ((op == ALU_DIV || op == ALU_REM) && dividend[31])
      abs_dividend = (~dividend) + 32'd1;
    if ((op == ALU_DIV || op == ALU_REM) && divisor[31])
      abs_divisor = (~divisor) + 32'd1;

    remainder_shifted = {remainder_q[31:0], quotient_q[31]};
    quotient_next = {quotient_q[30:0], 1'b0};
    if (remainder_shifted >= {1'b0, divisor_q}) begin
      remainder_next = remainder_shifted[31:0] - divisor_q;
      quotient_next[0] = 1'b1;
    end else begin
      remainder_next = remainder_shifted[31:0];
    end

    quotient_final = quotient_next;
    remainder_final = remainder_next;
    if (neg_quotient_q)
      quotient_final = (~quotient_next) + 32'd1;
    if (neg_remainder_q)
      remainder_final = (~remainder_next) + 32'd1;

    busy = (state_q == DIV_RUN);
    done = (state_q == DIV_DONE);
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q          <= DIV_IDLE;
      count_q          <= 6'd0;
      quotient_q       <= 32'd0;
      divisor_q        <= 32'd0;
      remainder_q      <= 32'd0;
      quotient_op_q    <= 1'b0;
      neg_quotient_q   <= 1'b0;
      neg_remainder_q  <= 1'b0;
      result           <= 32'd0;
    end else begin
      case (state_q)
        DIV_IDLE: begin
          if (start) begin
            quotient_op_q   <= (op == ALU_DIV || op == ALU_DIVU);
            neg_quotient_q  <= ((op == ALU_DIV) && (dividend[31] ^ divisor[31]));
            neg_remainder_q <= ((op == ALU_REM) && dividend[31]);
            count_q         <= 6'd0;
            remainder_q     <= 32'd0;

            // RV32M specifies these results directly; avoid iterating them.
            if (divisor == 32'd0) begin
              result  <= (op == ALU_DIV || op == ALU_DIVU)
                       ? 32'hFFFFFFFF : dividend;
              state_q <= DIV_DONE;
            end else if ((op == ALU_DIV || op == ALU_REM) &&
                         dividend == 32'h80000000 && divisor == 32'hFFFFFFFF) begin
              result  <= (op == ALU_DIV) ? 32'h80000000 : 32'd0;
              state_q <= DIV_DONE;
            end else begin
              quotient_q <= abs_dividend;
              divisor_q  <= abs_divisor;
              state_q    <= DIV_RUN;
            end
          end
        end

        DIV_RUN: begin
          remainder_q <= remainder_next;
          quotient_q  <= quotient_next;
          count_q     <= count_q + 6'd1;
          if (count_q == 6'd31) begin
            result  <= quotient_op_q ? quotient_final : remainder_final;
            state_q <= DIV_DONE;
          end
        end

        DIV_DONE: begin
          if (consume)
            state_q <= DIV_IDLE;
        end

        default: state_q <= DIV_IDLE;
      endcase
    end
  end

endmodule
