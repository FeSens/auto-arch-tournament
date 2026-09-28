// rtl/div_unit.sv
//
// Iterative RV32M divide/remainder unit (DIV / DIVU / REM / REMU). Keeps
// the divider off the one-cycle EX result path: the EX stage starts it
// when a DIV-class op reaches EX, holds IF/ID/EX while it iterates, and
// bubbles EX/MEM until `done`.
//
// Algorithm: radix-2 restoring division on absolute values, one quotient
// bit per cycle (32 iterations), then one fixup cycle applying the sign.
// RV32M corner cases fall out of the datapath plus one sign-flag tweak:
//   x / 0         -> quotient all ones (every trial subtract of 0 succeeds);
//                    the quotient negate is suppressed so DIV gives -1 too
//   x % 0         -> remainder = |x|, negated back to x for signed REM
//   INT_MIN / -1  -> |INT_MIN| / 1 = 0x80000000, signs cancel -> INT_MIN
//   INT_MIN % -1  -> remainder 0
//
// FSM:  IDLE --start--> BUSY (32 cycles) --> FIX --> DONE --ack--> IDLE
// The result is held in DONE until the EX/MEM register actually advances
// (`ack` = !stall_ex_mem). Operands are latched at start, so later changes
// in forwarding sources cannot corrupt the running divide.
//
// `result` is zero whenever the unit is IDLE (result_q is cleared on the
// DONE->IDLE handshake), so the EX stage can OR it into the ALU result
// without a select: the ALU drives 0 for DIV-class ops, and the divider
// drives 0 for everything else.
//
// Under RISCV_FORMAL_ALTOPS the unit returns the riscv-formal ALTOPS
// stand-in ((a - b) ^ const) through the same FSM with a short fixed
// latency (start -> FIX -> DONE), so formal still exercises the busy /
// done stall machinery inside the BMC depth budget.
//
// Latency:        start cycle + 32 iterations + 1 fixup, then DONE
//                 (ALTOPS: start cycle + 1, then DONE).
// RVFI fields:    feeds rd_wdata of DIV/DIVU/REM/REMU via EX/MEM.alu_result.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,    // DIV-class op in EX and unit idle
  input  logic        ack,      // EX/MEM advances this cycle
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        idle,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] ST_IDLE = 2'd0;
  localparam logic [1:0] ST_BUSY = 2'd1;
  localparam logic [1:0] ST_FIX  = 2'd2;
  localparam logic [1:0] ST_DONE = 2'd3;

  logic [1:0]  state_q;
  logic [31:0] result_q;

  assign idle   = (state_q == ST_IDLE);
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
            state_q  <= ST_FIX;
          end
        end
        ST_BUSY: state_q <= ST_FIX;
        ST_FIX:  state_q <= ST_DONE;
        ST_DONE: begin
          if (ack) begin
            result_q <= 32'b0;
            state_q  <= ST_IDLE;
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end
`else
  logic [31:0] divisor_q;    // |b|
  logic [31:0] quo_q;        // shifts |a| out of the top, quotient bits in
  logic [31:0] rem_q;        // partial remainder (always < divisor_q)
  logic [4:0]  count_q;
  logic        neg_q;        // negate the selected result in FIX
  logic        want_rem_q;

  logic        signed_op;
  logic        want_rem;
  logic        a_neg;
  logic        b_neg;
  logic [31:0] abs_a;
  logic [31:0] abs_b;
  logic        b_zero;

  // diff[33] is the borrow of the trial subtract; diff[32] is always 0
  // when the subtract succeeds (partial remainder < 2 * divisor).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        take;
  logic [31:0] rem_next;
  logic [31:0] fix_sel;

  always_comb begin
    signed_op = (op == ALU_DIV) || (op == ALU_REM);
    want_rem  = (op == ALU_REM) || (op == ALU_REMU);
    a_neg     = signed_op && a[31];
    b_neg     = signed_op && b[31];
    abs_a     = a_neg ? (~a + 32'd1) : a;
    abs_b     = b_neg ? (~b + 32'd1) : b;
    b_zero    = (b == 32'b0);

    diff      = {1'b0, rem_q, quo_q[31]} - {2'b00, divisor_q};
    take      = !diff[33];
    rem_next  = take ? diff[31:0] : {rem_q[30:0], quo_q[31]};

    fix_sel   = want_rem_q ? rem_q : quo_q;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q    <= ST_IDLE;
      result_q   <= 32'b0;
      divisor_q  <= 32'b0;
      quo_q      <= 32'b0;
      rem_q      <= 32'b0;
      count_q    <= 5'b0;
      neg_q      <= 1'b0;
      want_rem_q <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start) begin
            divisor_q  <= abs_b;
            quo_q      <= abs_a;
            rem_q      <= 32'b0;
            count_q    <= 5'd0;
            want_rem_q <= want_rem;
            // REM takes the dividend's sign. DIV takes sign(a)^sign(b),
            // except x/0 which must stay all-ones (-1).
            neg_q      <= want_rem ? a_neg : ((a_neg ^ b_neg) && !b_zero);
            state_q    <= ST_BUSY;
          end
        end

        ST_BUSY: begin
          quo_q   <= {quo_q[30:0], take};
          rem_q   <= rem_next;
          count_q <= count_q + 5'd1;
          if (count_q == 5'd31) state_q <= ST_FIX;
        end

        ST_FIX: begin
          result_q <= neg_q ? (~fix_sel + 32'd1) : fix_sel;
          state_q  <= ST_DONE;
        end

        ST_DONE: begin
          if (ack) begin
            result_q <= 32'b0;
            state_q  <= ST_IDLE;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end
`endif

endmodule
