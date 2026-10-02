// rtl/muldiv.sv
//
// Multi-cycle RV32M unit that lives beside the EX stage. Replaces the
// combinational multipliers / dividers that used to sit in alu.sv.
//
// Protocol (EX-stage view):
//   - `req` is high while an M-extension instruction sits in EX (ID/EX is
//     held for as long as `busy`, so op/req are stable). `a`/`b` are the
//     already-forwarded rs1/rs2; they are only sampled on the first cycle
//     (state IDLE, !done) and latched into a_q/b_q, so later forwarding
//     changes do not matter.
//   - `busy` = req && !done. While busy the core holds IF/ID/EX and
//     inserts bubbles into EX/MEM.
//   - `done` is a registered flag. On the cycle it is high `result` is the
//     RV32M result. `done` is cleared on the edge where the op leaves EX
//     (req still high, advance high). a_q/b_q stay valid through the done
//     cycle so RVFI sees the real operands.
//   - `advance` = !dmem stall. The FSM and the divider datapath only move
//     when advance is high; if the stall lands on the done cycle the result
//     and done flag simply stay put.
//
// Multiply (shared 33x33 signed multiplier, MUL/MULH/MULHU/MULHSU):
//   c0  latch operands
//   c1  four <=18x18 signed partial products into registers (one DSP each)
//   c2  3-term 64-bit add + low/high select into res_q
//   c3  done (EX/MEM captures result)             -> 3 busy cycles
//
// Divide (1 bit/cycle restoring divider on |a|, |b|):
//   c0  latch operands
//   c1  |a|, |b|; b==0 short-circuits (q=all ones, r=a)
//   c2..c33  32 shift/subtract iterations
//   c34 sign fix-up into res_q
//   c35 done                                      -> 35 busy cycles
//   INT_MIN / -1 falls out of the abs-based path (q=INT_MIN, r=0).
//
// Latency:        3 (mul) / 35 (div) extra EX cycles.
// RVFI fields:    result feeds rd_wdata; a_q/b_q feed rs1_rdata/rs2_rdata.
module muldiv (
  input  logic        clock,
  input  logic        reset,
  input  logic        advance,   // FSM may advance (no dmem stall)
  input  logic        req,       // an M op is in EX
  input  logic [4:0]  op,        // ALU_MUL .. ALU_REMU
  input  logic [31:0] a,         // forwarded rs1
  input  logic [31:0] b,         // forwarded rs2
  output logic        busy,      // req && !done
  output logic        done,      // result valid this cycle (registered)
  output logic [31:0] result,
  output logic [31:0] a_lat,     // latched operands (valid while !busy && req)
  output logic [31:0] b_lat
);

  localparam logic [2:0] S_IDLE     = 3'd0;
  localparam logic [2:0] S_MUL_PP   = 3'd1;
  localparam logic [2:0] S_MUL_SUM  = 3'd2;
  localparam logic [2:0] S_DIV_INIT = 3'd3;
  localparam logic [2:0] S_DIV_ITER = 3'd4;
  localparam logic [2:0] S_DIV_FIX  = 3'd5;

  logic [2:0]  state;
  logic        done_q;
  logic [4:0]  op_q;
  logic [31:0] a_q;
  logic [31:0] b_q;
  logic [31:0] res_q;

  assign done    = done_q;
  assign busy    = req && !done_q;
  assign result  = res_q;
  assign a_lat   = a_q;
  assign b_lat   = b_q;

  // ── Operand latch ──────────────────────────────────────────────────────
  logic start;
  assign start = advance && req && !done_q && (state == S_IDLE);

  always_ff @(posedge clock) begin
    if (start) begin
      op_q <= op;
      a_q  <= a;
      b_q  <= b;
    end
  end

  // ── Multiplier datapath ────────────────────────────────────────────────
  // a_ext = {sa & a[31], a} (33-bit signed) split as a_hi*2^17 + a_lo with
  // a_lo = a[16:0] (unsigned, zero-extended to 18b signed) and
  // a_hi = a_ext[32:17] (16b signed, sign-extended to 18b). Every partial
  // product is then a signed 18x18 multiply (one Gowin DSP).
  logic sa, sb, ea, eb;
  logic signed [17:0] a_lo, a_hi, b_lo, b_hi;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [35:0] p_ll, p_lh, p_hl, p_hh;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    sa = (op_q == ALU_MULH) || (op_q == ALU_MULHSU);
    sb = (op_q == ALU_MULH);
    ea = sa && a_q[31];
    eb = sb && b_q[31];
    a_lo = {1'b0, a_q[16:0]};
    b_lo = {1'b0, b_q[16:0]};
    a_hi = {{3{ea}}, a_q[31:17]};
    b_hi = {{3{eb}}, b_q[31:17]};
    p_ll = a_lo * b_lo;
    p_lh = a_lo * b_hi;
    p_hl = a_hi * b_lo;
    p_hh = a_hi * b_hi;
  end

  // Partial-product registers (free running: a_q/b_q/op_q are stable from
  // c1 until the op leaves EX, so they always hold the right products by
  // the time S_MUL_SUM reads them). Only the bits that survive the 64-bit
  // truncation are kept.
  logic [33:0]        pp_ll;   // 17x17 unsigned, < 2^34
  logic signed [32:0] pp_lh;   // 17u x 16s
  logic signed [32:0] pp_hl;
  logic [29:0]        pp_hh;   // lands at bit 34, only [29:0] survive

  always_ff @(posedge clock) begin
    pp_ll <= p_ll[33:0];
    pp_lh <= p_lh[32:0];
    pp_hl <= p_hl[32:0];
    pp_hh <= p_hh[29:0];
  end

  logic signed [33:0] pp_mid;
  logic [63:0]        prod;
  always_comb begin
    pp_mid = {pp_lh[32], pp_lh} + {pp_hl[32], pp_hl};
    prod   = {pp_hh, pp_ll} + {{13{pp_mid[33]}}, pp_mid, 17'b0};
  end

  // ── Divider datapath ───────────────────────────────────────────────────
  logic        sgn_div;    // DIV / REM
  logic        is_rem;     // REM / REMU
  logic        neg_q;
  logic        neg_r;
  logic [31:0] abs_a;
  logic [31:0] abs_b;
  logic [31:0] quo_q;
  logic [31:0] rem_q;
  logic [31:0] dvsr_q;
  logic [4:0]  cnt_q;

  logic [32:0] shifted;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;       // [33] = borrow; [32] is always 0 when ge
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] fix_q;
  logic [31:0] fix_r;

  always_comb begin
    sgn_div = (op_q == ALU_DIV) || (op_q == ALU_REM);
    is_rem  = (op_q == ALU_REM) || (op_q == ALU_REMU);
    neg_q   = sgn_div && (a_q[31] ^ b_q[31]);
    neg_r   = sgn_div && a_q[31];
    abs_a   = (sgn_div && a_q[31]) ? (32'b0 - a_q) : a_q;
    abs_b   = (sgn_div && b_q[31]) ? (32'b0 - b_q) : b_q;

    shifted = {rem_q, quo_q[31]};
    diff    = {1'b0, shifted} - {2'b0, dvsr_q};
    ge      = !diff[33];

    fix_q   = neg_q ? (32'b0 - quo_q) : quo_q;
    fix_r   = neg_r ? (32'b0 - rem_q) : rem_q;
  end

  // ── FSM ────────────────────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      state  <= S_IDLE;
      done_q <= 1'b0;
    end else if (advance) begin
      case (state)
        S_IDLE: begin
          if (done_q || !req) begin
            done_q <= 1'b0;            // result consumed (or op withdrawn)
          end else begin
            state <= (op >= ALU_DIV) ? S_DIV_INIT : S_MUL_PP;
          end
        end

        S_MUL_PP: state <= S_MUL_SUM;

        S_MUL_SUM: begin
          res_q  <= (op_q == ALU_MUL) ? prod[31:0] : prod[63:32];
          done_q <= 1'b1;
          state  <= S_IDLE;
        end

        S_DIV_INIT: begin
          quo_q  <= abs_a;
          dvsr_q <= abs_b;
          rem_q  <= 32'b0;
          cnt_q  <= 5'd0;
          if (b_q == 32'b0) begin
            // RV32M: x/0 = all ones, x%0 = x.
            res_q  <= is_rem ? a_q : 32'hFFFFFFFF;
            done_q <= 1'b1;
            state  <= S_IDLE;
          end else begin
            state <= S_DIV_ITER;
          end
        end

        S_DIV_ITER: begin
          rem_q <= ge ? diff[31:0] : shifted[31:0];
          quo_q <= {quo_q[30:0], ge};
          cnt_q <= cnt_q + 5'd1;
          if (cnt_q == 5'd31) state <= S_DIV_FIX;
        end

        S_DIV_FIX: begin
          res_q  <= is_rem ? fix_r : fix_q;
          done_q <= 1'b1;
          state  <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
