// rtl/divider.sv
//
// Iterative radix-2 restoring divider for DIV / DIVU / REM / REMU.
//
// Replaces the combinational `/` and `%` operators that used to live in
// alu.sv: those were a 32-stage subtract array that dominated both the
// LUT count and the clock period. This unit does one 32-bit
// subtract-and-select per cycle instead.
//
// Protocol (all inputs sampled on the rising edge):
//   - `start` is honoured only in IDLE (and only when `hold` is low).
//     `a`/`b`/`is_signed`/`want_rem` are latched on that edge, so the
//     caller may drop them afterwards (the EX-stage forwarding selects go
//     stale a couple of cycles into a divide).
//   - `hold` freezes the FSM (dmem stall in the pipeline).
//   - `done` is high while the registered `result` is valid (DONE state).
//     The FSM returns to IDLE on the first edge with `hold` low, i.e. the
//     edge at which the caller consumes `result`.
//
// FSM:  IDLE -> RUN x32 -> FIXUP -> DONE -> IDLE
//   IDLE : on start, latch |a| (dividend/quotient reg) and |b| (divisor).
//   RUN  : {rem, quo} <<= 1; if rem_sh >= |b| then rem -= |b|, quo[0] = 1.
//   FIXUP: negate quotient (sign(a)^sign(b), b != 0) or remainder
//          (sign(a)) into the result register.
//   DONE : result valid.
//
// RV32M corner cases fall out of the unsigned loop:
//   b == 0           : quotient = 0xFFFFFFFF, remainder = |a| (-> a after the
//                      sign fixup); the quotient negation is suppressed so
//                      signed DIV by 0 stays -1.
//   INT_MIN / -1     : |INT_MIN| = 0x80000000 (unsigned), |-1| = 1, signs
//                      equal -> quotient 0x80000000, remainder 0.
//
// Latency:        `done` goes high 34 cycles after the cycle in which
//                 `start` is presented (cycle 0 = IDLE/latch, 1..32 = RUN,
//                 33 = FIXUP, 34 = DONE), so a divide occupies EX for 35
//                 cycles when nothing else stalls it.
// RVFI fields:    feeds rd_wdata of DIV/DIVU/REM/REMU via EX/MEM.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        hold,        // freeze FSM (dmem stall)
  input  logic        start,       // request a new divide (honoured in IDLE)
  input  logic        is_signed,   // 1 = DIV/REM, 0 = DIVU/REMU
  input  logic        want_rem,    // 1 = REM/REMU, 0 = DIV/DIVU
  input  logic [31:0] a,           // dividend (rs1)
  input  logic [31:0] b,           // divisor  (rs2)
  output logic        busy,        // RUN or FIXUP
  output logic        done,        // DONE: `result` valid
  output logic [31:0] result
);

  localparam logic [1:0] S_IDLE  = 2'd0;
  localparam logic [1:0] S_RUN   = 2'd1;
  localparam logic [1:0] S_FIXUP = 2'd2;
  localparam logic [1:0] S_DONE  = 2'd3;

  logic [1:0]  state;
  logic [4:0]  cnt;
  logic [31:0] rem;       // partial remainder
  logic [31:0] quo;       // dividend shifts out of the top, quotient in
  logic [31:0] dvs;       // |divisor|
  logic        want_rem_q;
  logic        neg_q_raw; // sign(a) ^ sign(b), signed ops only
  logic        neg_r;     // sign(a), signed ops only
  logic        dvs_zero;
  logic [31:0] res_q;

  // ── One restoring-division step ───────────────────────────────────────
  logic [32:0] rem_sh;
  logic [32:0] sub;
  logic        ge;
  always_comb begin
    rem_sh = {rem, quo[31]};
    sub    = {1'b0, rem_sh[31:0]} - {1'b0, dvs};   // sub[32] = borrow
    ge     = rem_sh[32] | ~sub[32];
  end

  // ── Operand absolute values (signed ops) ──────────────────────────────
  logic        a_neg;
  logic        b_neg;
  logic [31:0] a_abs;
  logic [31:0] b_abs;
  always_comb begin
    a_neg = is_signed & a[31];
    b_neg = is_signed & b[31];
    a_abs = a_neg ? (32'b0 - a) : a;
    b_abs = b_neg ? (32'b0 - b) : b;
  end

  // ── Result fixup (shared negator for quotient / remainder) ────────────
  logic [31:0] fix_in;
  logic        fix_neg;
  always_comb begin
    fix_in  = want_rem_q ? rem   : quo;
    fix_neg = want_rem_q ? neg_r : (neg_q_raw & ~dvs_zero);
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else if (!hold) begin
      case (state)
        S_IDLE:  if (start)          state <= S_RUN;
        S_RUN:   if (cnt == 5'd31)   state <= S_FIXUP;
        S_FIXUP:                     state <= S_DONE;
        default:                     state <= S_IDLE;   // S_DONE
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (!hold) begin
      case (state)
        S_IDLE: begin
          quo        <= a_abs;
          dvs        <= b_abs;
          rem        <= 32'b0;
          cnt        <= 5'd0;
          want_rem_q <= want_rem;
          neg_q_raw  <= a_neg ^ b_neg;
          neg_r      <= a_neg;
        end
        S_RUN: begin
          rem      <= ge ? sub[31:0] : rem_sh[31:0];
          quo      <= {quo[30:0], ge};
          cnt      <= cnt + 5'd1;
          dvs_zero <= (dvs == 32'b0);
        end
        S_FIXUP: begin
          res_q <= fix_neg ? (32'b0 - fix_in) : fix_in;
        end
        default: ;
      endcase
    end
  end

  assign busy   = (state == S_RUN) || (state == S_FIXUP);
  assign done   = (state == S_DONE);
  assign result = res_q;

endmodule
