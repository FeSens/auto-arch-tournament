// rtl/div_unit.sv
//
// Iterative RV32M DIV / DIVU / REM / REMU unit. Sits beside the
// single-cycle ALU in EX behind a start/busy/done handshake, so the
// divider is off the universal ID/EX -> fwd mux -> ALU -> EX/MEM path.
//
// Sequencing (real arithmetic):
//   IDLE  --start-->  latch raw operands + op                   (1 cycle)
//   SIGN              rq = a, dvs = b, operand signs            (1 cycle)
//   PREP              rq = |a|, dvs = |b|, rem = 0, flag b == 0 (1 cycle)
//   ITER              radix-2 restoring step in two phases:
//                     compare (register take / trial - dvs),
//                     then apply (shift, select the remainder);
//                     the result sign is settled into neg_q     (64 cycles)
//   FIXUP             select quotient/remainder, apply sign     (1 cycle)
//   DONE              result valid; sticky until ack
//
// RV32M corner cases fall out of the unsigned datapath:
//   x / 0        -> quotient all ones, remainder = |x|. The quotient sign
//                   fixup is suppressed on b == 0 so DIV returns -1 for
//                   negative dividends; REM's fixup restores the dividend.
//   INT_MIN / -1 -> |a| = 0x80000000, |b| = 1: quotient 0x80000000 whose
//                   negation is itself (= INT_MIN), remainder 0.
//
// Timing: the start edge is a plain enabled copy of the forwarded
// operands into a_q / b_q, so no divider logic follows EX's forwarding
// mux; the signs and the rq / dvs loads come one cycle later from those
// registers (SIGN). The ITER compare's 34-bit carry chain ends in flops
// (take_q, step_diff_q) instead of fanning take out to 64 muxes in the
// same cycle. Every conditional negate is FF -> one LUT4 (source select
// xor registered enable) -> carry chain -> FF. The enables (neg_q,
// dneg_q) and the source select (sel_rem_q) are registers, never decoded
// on the fly. CoreMark retires no divides in its timed window, so the
// extra cycles are free there.
//
// Under RISCV_FORMAL_ALTOPS, start goes straight to PREP, which writes
// the riscv-formal ALTOPS substitution ((a - b) ^ mask, per insn_div*.v /
// insn_rem*.v) from a_q / b_q and goes to DONE. Same handshake, fixed
// short latency, so the formal checks still exercise the EX interlock
// within the BMC depth budget.
//
// The raw latched operands are exported (a_lat / b_lat) so EX can report
// them as RVFI rs1_rdata / rs2_rdata: the forwarding sources that fed
// them drain while the divide waits in EX.
//
// Latency:        start -> done = 67 cycles (real), 2 cycles (ALTOPS).
//                 result / done are registered outputs.
// RVFI fields:    rd_wdata of DIV/DIVU/REM/REMU (via EX/MEM alu_result),
//                 rs1_rdata / rs2_rdata (via a_lat / b_lat).
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,        // accepted only in IDLE
  input  logic        ack,          // DONE -> IDLE (EX/MEM took the result)
  input  logic        is_rem,       // funct3[1]: REM / REMU
  input  logic        is_unsigned,  // funct3[0]: DIVU / REMU
  input  logic [31:0] a,            // dividend (post-forward rs1)
  input  logic [31:0] b,            // divisor  (post-forward rs2)
  output logic        busy,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_lat,
  output logic [31:0] b_lat
);

  localparam logic [2:0] ST_IDLE  = 3'd0;
  localparam logic [2:0] ST_PREP  = 3'd1;
  localparam logic [2:0] ST_ITER  = 3'd2;
  localparam logic [2:0] ST_FIXUP = 3'd3;
  localparam logic [2:0] ST_DONE  = 3'd4;
  localparam logic [2:0] ST_SIGN  = 3'd5;

  logic [2:0]  state_q;
  logic [31:0] a_q;         // raw dividend (held until next start, RVFI)
  logic [31:0] b_q;         // raw divisor  (held until next start, RVFI)
  logic        is_rem_q;
  logic        is_uns_q;
  logic [31:0] rq_q;        // raw a -> |a| -> quotient (shifted in) ->
                            // final result after FIXUP
  logic [31:0] rem_q;       // partial remainder
  logic [31:0] dvs_q;       // raw b -> |b|
  logic [4:0]  cnt_q;
  logic        neg_q;       // negate rq path: PREP = a<0, FIXUP = result<0
  logic        dneg_q;      // negate dvs in PREP (b<0, signed op)
  logic        sel_rem_q;   // FIXUP source: 1 = rem_q, 0 = rq_q
  logic        b_nz_q;      // b != 0, registered in PREP, read in ITER
  logic        iter_hi_q;   // ITER phase: 0 = compare, 1 = apply
  logic        take_q;      // compare phase: trial >= dvs
  logic [31:0] step_diff_q; // compare phase: trial - dvs (low 32 bits)

  assign busy   = (state_q != ST_IDLE) && (state_q != ST_DONE);
  assign done   = (state_q == ST_DONE);
  assign result = rq_q;
  assign a_lat  = a_q;
  assign b_lat  = b_q;

  // ── Conditional negators (PREP: |a| and |b|, FIXUP: result sign) ──────
  // abs_b / res_neg are only read by the real-arithmetic PREP arm.
  logic [31:0] neg_src;
  logic [31:0] neg_out;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] abs_b;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    neg_src = sel_rem_q ? rem_q : rq_q;
    neg_out = (neg_src ^ {32{neg_q}}) + {31'b0, neg_q};
    abs_b   = (dvs_q ^ {32{dneg_q}}) + {31'b0, dneg_q};
  end

  // ── Result sign (from the raw operands held in a_q / b_q) ─────────────
  // b != 0 is registered in PREP (b_nz_q) and folded into neg_q during
  // ITER, so the 32-bit zero detect and the sign logic are two short
  // register-to-register paths instead of one long one. neg_q is not
  // read again until FIXUP, and the fold is idempotent over the ITER
  // cycles.
  /* verilator lint_off UNUSEDSIGNAL */
  logic a_neg;
  logic b_neg;
  logic res_neg;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    a_neg   = !is_uns_q && a_q[31];
    b_neg   = !is_uns_q && b_q[31];
    // REM takes the dividend's sign; DIV is negative iff the signs differ,
    // except x / 0 which must stay all ones (ITER clears neg_q for that).
    res_neg = is_rem_q ? a_neg : (a_neg ^ b_neg);
  end

  // ── ITER: one restoring step, split over two cycles ───────────────────
  // trial = {rem, next dividend bit}; diff[33] is the borrow (trial < dvs).
  // When the subtract is taken the difference is < dvs, so diff[32] is 0.
  // The compare phase registers take / diff[31:0]; rem_q and rq_q do not
  // change until the apply phase, so trial is the same in both phases.
  logic [32:0] trial;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        take;
  always_comb begin
    trial = {rem_q, rq_q[31]};
    diff  = {1'b0, trial} - {2'b0, dvs_q};
    take  = !diff[33];
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;
  always_comb begin
    case ({is_rem_q, is_uns_q})
      2'b00:   alt_result = (a_q - b_q) ^ 32'h7f8529ec;  // DIV
      2'b01:   alt_result = (a_q - b_q) ^ 32'h10e8fd70;  // DIVU
      2'b10:   alt_result = (a_q - b_q) ^ 32'h8da68fa5;  // REM
      default: alt_result = (a_q - b_q) ^ 32'h3138d0e1;  // REMU
    endcase
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q     <= ST_IDLE;
      a_q         <= 32'b0;
      b_q         <= 32'b0;
      is_rem_q    <= 1'b0;
      is_uns_q    <= 1'b0;
      rq_q        <= 32'b0;
      rem_q       <= 32'b0;
      dvs_q       <= 32'b0;
      cnt_q       <= 5'b0;
      neg_q       <= 1'b0;
      dneg_q      <= 1'b0;
      sel_rem_q   <= 1'b0;
      b_nz_q      <= 1'b0;
      iter_hi_q   <= 1'b0;
      take_q      <= 1'b0;
      step_diff_q <= 32'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start) begin
            a_q       <= a;
            b_q       <= b;
            is_rem_q  <= is_rem;
            is_uns_q  <= is_unsigned;
`ifdef RISCV_FORMAL_ALTOPS
            state_q   <= ST_PREP;
`else
            state_q   <= ST_SIGN;
`endif
          end
        end

        ST_SIGN: begin
          rq_q      <= a_q;
          dvs_q     <= b_q;
          neg_q     <= !is_uns_q && a_q[31];
          dneg_q    <= !is_uns_q && b_q[31];
          sel_rem_q <= 1'b0;
          state_q   <= ST_PREP;
        end

        ST_PREP: begin
`ifdef RISCV_FORMAL_ALTOPS
          rq_q      <= alt_result;
          state_q   <= ST_DONE;
`else
          rq_q      <= neg_out;              // |a|  (sel_rem_q = 0)
          dvs_q     <= abs_b;                // |b|
          rem_q     <= 32'b0;
          cnt_q     <= 5'd31;
          neg_q     <= res_neg;              // FIXUP sign, before b == 0
          b_nz_q    <= (b_q != 32'b0);
          state_q   <= ST_ITER;
`endif
        end

        ST_ITER: begin
          iter_hi_q <= !iter_hi_q;
          if (!iter_hi_q) begin
            take_q      <= take;
            step_diff_q <= diff[31:0];
          end else begin
            rem_q     <= take_q ? step_diff_q : trial[31:0];
            rq_q      <= {rq_q[30:0], take_q};
            cnt_q     <= cnt_q - 5'd1;
            sel_rem_q <= is_rem_q;
            neg_q     <= neg_q && (is_rem_q || b_nz_q);  // x / 0: no fixup
            if (cnt_q == 5'd0) state_q <= ST_FIXUP;
          end
        end

        ST_FIXUP: begin
          rq_q    <= neg_out;
          state_q <= ST_DONE;
        end

        ST_DONE: begin
          if (ack) state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

endmodule
