// rtl/divider.sv
//
// Sequential RV32M divider for DIV / DIVU / REM / REMU. Restoring radix-2,
// one quotient bit per cycle on operand magnitudes, followed by a
// registered sign fix-up. Keeps the 32-level subtract array of a
// combinational `/` and `%` out of the EX-stage critical path.
//
// FSM:
//   IDLE -> start: latch raw a/b (post-forward) and op        -> ABS
//   ABS  : quo <= |a|, dvs <= |b|, rem <= 0, sign flags       -> RUN
//   RUN  : NITER trial subtracts of {rem, quo[31]} - dvs      -> FIX
//   FIX  : result_q <= (optionally negated) quotient/remainder -> DONE
//   DONE : result_q valid; leave to IDLE when `advance` (EX/MEM captures)
//
// RV32M special cases fall out of the magnitude algorithm:
//   divide by zero: q = all ones, r = |a|. The quotient negate is
//                   suppressed when b == 0 and the remainder negate
//                   (dividend negative) restores r = a.
//   INT_MIN / -1  : |a| = 2^31, |b| = 1 -> q = 0x80000000 (signs equal,
//                   no negate), r = 0.
//
// Under RISCV_FORMAL_ALTOPS the FSM and handshake are unchanged, but RUN
// lasts only 2 cycles and the result is riscv-formal's (a - b) ^ const
// stand-in on the latched operands, so the liveness window still holds.
//
// Latency:        start + ABS + NITER + FIX -> result in DONE
//                 (35 cycles in EX for NITER = 32).
// RVFI fields:    rd_wdata of DIV*/REM* (via EX/MEM alu_result);
//                 a_latched/b_latched feed rs1_rdata/rs2_rdata.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,      // DIV* in EX, divider idle, EX/MEM free
  input  logic        is_rem,     // REM / REMU
  input  logic        is_signed,  // DIV / REM
  input  logic [31:0] a,          // post-forward rs1
  input  logic [31:0] b,          // post-forward rs2
  input  logic        advance,    // EX/MEM is not held this cycle
  output logic        idle,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_latched,
  output logic [31:0] b_latched
);

`ifdef RISCV_FORMAL_ALTOPS
  localparam logic [4:0] LAST_ITER = 5'd1;
`else
  localparam logic [4:0] LAST_ITER = 5'd31;
`endif

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_ABS  = 3'd1;
  localparam logic [2:0] S_RUN  = 3'd2;
  localparam logic [2:0] S_FIX  = 3'd3;
  localparam logic [2:0] S_DONE = 3'd4;

  logic [2:0]  state;
  logic [4:0]  cnt;
  logic        rem_q, signed_q;
  logic        neg_q, neg_r;     // negate quotient / remainder in FIX
  logic [31:0] a_q, b_q;         // raw latched operands
  logic [31:0] quo_q;            // dividend shifts out, quotient shifts in
  logic [31:0] rem_r;            // partial remainder
  logic [31:0] dvs_q;            // |divisor|
  logic [31:0] result_q;

  // One restoring step: 33-bit trial subtract, sign bit selects.
  logic [32:0] trial;
  logic        a_neg, b_neg;
  logic [31:0] fix_sel;
  logic        fix_neg;

  always_comb begin
    trial   = {rem_r, quo_q[31]} - {1'b0, dvs_q};
    a_neg   = signed_q && a_q[31];
    b_neg   = signed_q && b_q[31];
    fix_sel = rem_q ? rem_r : quo_q;
    fix_neg = rem_q ? neg_r : neg_q;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state    <= S_IDLE;
      cnt      <= 5'd0;
      rem_q    <= 1'b0;
      signed_q <= 1'b0;
      neg_q    <= 1'b0;
      neg_r    <= 1'b0;
      a_q      <= 32'b0;
      b_q      <= 32'b0;
      quo_q    <= 32'b0;
      rem_r    <= 32'b0;
      dvs_q    <= 32'b0;
      result_q <= 32'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            a_q      <= a;
            b_q      <= b;
            rem_q    <= is_rem;
            signed_q <= is_signed;
            state    <= S_ABS;
          end
        end
        S_ABS: begin
          quo_q <= a_neg ? (32'b0 - a_q) : a_q;
          dvs_q <= b_neg ? (32'b0 - b_q) : b_q;
          rem_r <= 32'b0;
          neg_q <= (a_neg ^ b_neg) && (b_q != 32'b0);
          neg_r <= a_neg;
          cnt   <= 5'd0;
          state <= S_RUN;
        end
        S_RUN: begin
          if (!trial[32]) begin
            rem_r <= trial[31:0];
            quo_q <= {quo_q[30:0], 1'b1};
          end else begin
            rem_r <= {rem_r[30:0], quo_q[31]};
            quo_q <= {quo_q[30:0], 1'b0};
          end
          cnt <= cnt + 5'd1;
          if (cnt == LAST_ITER) state <= S_FIX;
        end
        S_FIX: begin
`ifdef RISCV_FORMAL_ALTOPS
          case ({rem_q, signed_q})
            2'b01:   result_q <= (a_q - b_q) ^ 32'h7f8529ec;  // DIV
            2'b00:   result_q <= (a_q - b_q) ^ 32'h10e8fd70;  // DIVU
            2'b11:   result_q <= (a_q - b_q) ^ 32'h8da68fa5;  // REM
            default: result_q <= (a_q - b_q) ^ 32'h3138d0e1;  // REMU
          endcase
`else
          result_q <= fix_neg ? (32'b0 - fix_sel) : fix_sel;
`endif
          state <= S_DONE;
        end
        S_DONE: begin
          if (advance) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign idle      = (state == S_IDLE);
  assign done      = (state == S_DONE);
  assign result    = result_q;
  assign a_latched = a_q;
  assign b_latched = b_q;

endmodule
