// rtl/muldiv.sv
//
// Registered multi-cycle RV32M unit: MUL/MULH/MULHSU/MULHU and
// DIV/DIVU/REM/REMU. Replaces the combinational `*`, `/`, `%` that used to
// live in alu.sv (the 150-level divider was the whole critical path).
//
// Handshake:
//   - start   : a new op is in EX. Accepted only while the unit is idle;
//               ignored otherwise (so it may be held high).
//   - op/a/b  : ALU op code (ALU_MUL..ALU_REMU) and the post-forward rs1/rs2.
//               While idle they are captured into a_lat/b_lat/flags every
//               cycle, so the values present on the `start` cycle are the
//               ones used; nothing is re-read afterwards because the
//               forwarding sources move on while EX is stalled.
//   - done    : flop; goes high when `result` is valid and stays high until
//               `consume`.
//   - consume : EX has taken the result; the unit returns to idle next cycle.
//   - a_lat/b_lat : the captured operands (RVFI rs1/rs2_rdata at commit).
//
// Timing (stall cycles seen by EX between start and the cycle done=1):
//   MUL*       : 2   (start, product register, done)
//   DIV*/REM*  : 35  (start, PREP, 32 x restoring step, FIX, done)
//
// Multiply: one shared signed 33x33 multiplier. Operands are sign-extended
// per op so that bits [63:0] of the product give MUL (low) and MULH/MULHSU/
// MULHU (high). prod is a free-running register (reg -> mult -> reg).
//
// Divide: radix-2 restoring divider on |a| / |b| with one 33-bit subtract
// per cycle; the sign fix-up happens in dedicated cycles from registers.
//   b == 0   : quotient = all ones (DIV/DIVU), remainder = a (REM/REMU).
//              The quotient negate is suppressed so DIV(-x, 0) = -1.
//   INT_MIN / -1 falls out of the unsigned algorithm: quo = 0x80000000
//              (negated back to itself), rem = 0.
//
// Latency:        see above.
// RVFI fields:    none directly (a_lat/b_lat feed rs1/rs2_rdata via EX/MEM).
module muldiv (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        consume,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_lat,
  output logic [31:0] b_lat
);

  // ── One-hot state ─────────────────────────────────────────────────────
  logic st_idle;
  logic st_mul;
  logic st_prep;
  logic st_div;
  logic st_fix;
  // `done` (port) is the DONE state.

  // ── Captured op flags ─────────────────────────────────────────────────
  logic a_sgn_q;     // multiplier: rs1 is signed
  logic b_sgn_q;     // multiplier: rs2 is signed
  logic hi_q;        // multiplier: take product[63:32]
  logic is_div_q;    // divide-class op (DIV/DIVU/REM/REMU)
  logic want_rem_q;  // REM/REMU
  logic sdiv_q;      // DIV/REM (signed)

  // ── Datapath registers ────────────────────────────────────────────────
  logic [63:0] prod;
  logic [31:0] den_q;
  logic [31:0] rem_q;
  logic [31:0] quo_q;   // dividend/quotient shift register, then the result
  logic [4:0]  cnt_q;
  logic        qneg_q;
  logic        rneg_q;

  // ── Operand / flag capture (every cycle while idle) ───────────────────
  always_ff @(posedge clock) begin
    if (st_idle) begin
      a_lat      <= a;
      b_lat      <= b;
      a_sgn_q    <= (op != ALU_MULHU);
      b_sgn_q    <= (op == ALU_MUL) || (op == ALU_MULH);
      hi_q       <= (op != ALU_MUL);
      is_div_q   <= (op >= ALU_DIV);
      want_rem_q <= (op == ALU_REM) || (op == ALU_REMU);
      sdiv_q     <= (op == ALU_DIV) || (op == ALU_REM);
    end
  end

  // ── FSM ───────────────────────────────────────────────────────────────
  logic cnt_last;
  assign cnt_last = &cnt_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      st_idle <= 1'b1;
      st_mul  <= 1'b0;
      st_prep <= 1'b0;
      st_div  <= 1'b0;
      st_fix  <= 1'b0;
      done    <= 1'b0;
    end else begin
      if (st_idle && start) begin
        st_idle <= 1'b0;
        if (op >= ALU_DIV) st_prep <= 1'b1;
        else               st_mul  <= 1'b1;
      end
      if (st_mul) begin
        st_mul <= 1'b0;
        done   <= 1'b1;
      end
      if (st_prep) begin
        st_prep <= 1'b0;
        st_div  <= 1'b1;
      end
      if (st_div && cnt_last) begin
        st_div <= 1'b0;
        st_fix <= 1'b1;
      end
      if (st_fix) begin
        st_fix <= 1'b0;
        done   <= 1'b1;
      end
      if (done && consume) begin
        done    <= 1'b0;
        st_idle <= 1'b1;
      end
    end
  end

  // ── Multiplier: shared signed 33x33, registered product ───────────────
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_p;   // [65:64] are sign copies of [63]
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    mul_a = {a_sgn_q & a_lat[31], a_lat};
    mul_b = {b_sgn_q & b_lat[31], b_lat};
    mul_p = mul_a * mul_b;
  end

  always_ff @(posedge clock) begin
    prod <= mul_p[63:0];
  end

  // ── Divider ───────────────────────────────────────────────────────────
  logic [31:0] a_abs;
  logic [31:0] b_abs;
  logic [32:0] sh;        // {rem, next dividend bit}
  // sh - den, bit 33 = borrow. diff[32] is always 0 when no borrow
  // (invariant rem < den), so only [31:0] and [33] are read.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] fix_val;

  always_comb begin
    a_abs = (sdiv_q && a_lat[31]) ? (32'b0 - a_lat) : a_lat;
    b_abs = (sdiv_q && b_lat[31]) ? (32'b0 - b_lat) : b_lat;

    sh   = {rem_q, quo_q[31]};
    diff = {1'b0, sh} - {2'b0, den_q};
    ge   = !diff[33];

    if (want_rem_q) fix_val = rneg_q ? (32'b0 - rem_q) : rem_q;
    else            fix_val = qneg_q ? (32'b0 - quo_q) : quo_q;
  end

  always_ff @(posedge clock) begin
    if (st_prep) begin
      quo_q  <= a_abs;
      den_q  <= b_abs;
      rem_q  <= 32'b0;
      cnt_q  <= 5'd0;
      qneg_q <= sdiv_q && (a_lat[31] ^ b_lat[31]) && (b_lat != 32'b0);
      rneg_q <= sdiv_q && a_lat[31];
    end else if (st_div) begin
      rem_q <= ge ? diff[31:0] : sh[31:0];
      quo_q <= {quo_q[30:0], ge};
      cnt_q <= cnt_q + 5'd1;
    end else if (st_fix) begin
      quo_q <= fix_val;
    end
  end

  // ── Result ────────────────────────────────────────────────────────────
  always_comb begin
    if (is_div_q) result = quo_q;
    else          result = hi_q ? prod[63:32] : prod[31:0];
  end

endmodule
