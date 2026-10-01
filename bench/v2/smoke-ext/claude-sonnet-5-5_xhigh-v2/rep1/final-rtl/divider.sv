// rtl/divider.sv
//
// Radix-2 restoring serial divider for DIV / DIVU / REM / REMU.
//
// The pipeline parks the divide in EX (ID/EX and PC hold, EX/MEM takes a
// bubble) until `done`. FSM (one-hot):
//
//   IDLE : wait for `start` (a DIV-class op is in EX and EX/MEM is not
//          dmem-stalled). On start latch the *raw* post-forwarding
//          operands and the op bits. No negation here so the forwarding
//          path into these registers is not lengthened.
//   PREP : one cycle. Compute |a| and |b| from the registered raw values,
//          clear the remainder, record the result signs.
//   RUN  : 32 cycles of restoring shift/subtract on the magnitudes:
//            sh = {rem, q[31]}        (33 bits: rem can reach 2^32-2)
//            if (sh >= |b|) rem = sh - |b|, q = {q[30:0], 1}
//            else           rem = sh,       q = {q[30:0], 0}
//          One 34-bit subtract + mux per cycle.
//   FIX  : one cycle. Conditional negate of the quotient or remainder.
//   DONE : `done` = 1, `result` valid. Back to IDLE when the instruction
//          advances out of EX (`advance`).
//
// RV32M corner cases fall out of the plain algorithm:
//   b == 0      : every trial subtract succeeds -> q = all ones, rem = |a|.
//                 Unsigned/REM: sign fix-up gives the dividend / all ones.
//                 Signed DIV by 0: the quotient negation is suppressed
//                 (neg_q requires b != 0) so the result stays all ones.
//   INT_MIN/-1  : |a| = 0x80000000, |b| = 1 -> q = 0x80000000, rem = 0;
//                 negating q (signs differ) gives 0x80000000 again.
//
// The latched operands a_q / b_q are exported so ex_stage can report the
// original rs1/rs2 values on RVFI after the forwarding selects have moved
// on while EX was parked.
//
// Under RISCV_FORMAL_ALTOPS the whole FSM is compiled out: done = 0 and the
// ALU's (a-b)^const stand-ins remain in force (ex_stage ties div_op to 0).
//
// Latency:        35 busy cycles + 1 done cycle per divide.
// RVFI fields:    a_q / b_q feed rs1_rdata / rs2_rdata; result feeds
//                 rd_wdata through the EX/MEM alu_result path.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,       // DIV-class op in EX and !stall_ex_mem
  input  logic        advance,     // EX/MEM accepts this cycle (!stall_ex_mem)
  input  logic [31:0] a,           // post-forwarding rs1
  input  logic [31:0] b,           // post-forwarding rs2
  input  logic        is_signed,   // DIV / REM
  input  logic        want_rem,    // REM / REMU
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_q,
  output logic [31:0] b_q
);

`ifdef RISCV_FORMAL_ALTOPS
  // Inert under ALTOPS: ex_stage never starts the divider and the ALU's
  // algebraic stand-ins produce the DIV/REM results.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = &{1'b0, clock, reset, start, advance, a, b, is_signed, want_rem};
  /* verilator lint_on UNUSEDSIGNAL */
  assign done   = 1'b0;
  assign result = 32'b0;
  assign a_q    = 32'b0;
  assign b_q    = 32'b0;
`else
  // ── FSM (one-hot) ───────────────────────────────────────────────────────
  logic st_idle, st_prep, st_run, st_fix, st_done;
  logic [4:0] cnt;
  logic       last;

  assign last = (cnt == 5'd31);

  always_ff @(posedge clock) begin
    if (reset) begin
      st_idle <= 1'b1;
      st_prep <= 1'b0;
      st_run  <= 1'b0;
      st_fix  <= 1'b0;
      st_done <= 1'b0;
    end else begin
      if (st_idle && start)         begin st_idle <= 1'b0; st_prep <= 1'b1; end
      if (st_prep)                  begin st_prep <= 1'b0; st_run  <= 1'b1; end
      if (st_run && last)           begin st_run  <= 1'b0; st_fix  <= 1'b1; end
      if (st_fix)                   begin st_fix  <= 1'b0; st_done <= 1'b1; end
      if (st_done && advance)       begin st_done <= 1'b0; st_idle <= 1'b1; end
    end
  end

  assign done = st_done;

  // ── Datapath ────────────────────────────────────────────────────────────
  logic [31:0] quo;      // dividend magnitude shifts out the top while
                         // quotient bits shift in at the bottom
  logic [31:0] rem;
  logic [31:0] dvs;      // |b|
  logic        sgn_q;    // latched is_signed
  logic        rem_q;    // latched want_rem
  logic        neg_q;    // negate quotient in FIX
  logic        neg_r;    // negate remainder in FIX

  logic        a_neg;
  logic        b_neg;
  assign a_neg = sgn_q & a_q[31];
  assign b_neg = sgn_q & b_q[31];

  // RUN: trial subtract. sh is 33 bits; the 34-bit result's MSB is the
  // borrow (sh < dvs).
  logic [32:0] sh;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;   // bit 32 is never read: only the borrow (33) and low word
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  assign sh   = {rem, quo[31]};
  assign diff = {1'b0, sh} - {2'b0, dvs};
  assign ge   = ~diff[33];

  // FIX: sign fix-up of whichever of quotient / remainder was asked for.
  logic [31:0] fix_x;
  logic        fix_neg;
  logic [31:0] fix_val;
  assign fix_x   = rem_q ? rem : quo;
  assign fix_neg = rem_q ? neg_r : neg_q;
  assign fix_val = fix_neg ? (32'b0 - fix_x) : fix_x;

  always_ff @(posedge clock) begin
    if (st_idle && start) begin
      a_q   <= a;
      b_q   <= b;
      sgn_q <= is_signed;
      rem_q <= want_rem;
    end
    if (st_prep) begin
      quo   <= a_neg ? (32'b0 - a_q) : a_q;
      dvs   <= b_neg ? (32'b0 - b_q) : b_q;
      rem   <= 32'b0;
      cnt   <= 5'd0;
      neg_r <= a_neg;
      // Signed DIV by zero must return all ones: no quotient negation.
      neg_q <= (a_neg ^ b_neg) & (b_q != 32'b0);
    end
    if (st_run) begin
      rem <= ge ? diff[31:0] : sh[31:0];
      quo <= {quo[30:0], ge};
      cnt <= cnt + 5'd1;
    end
    if (st_fix) begin
      quo <= fix_val;
    end
  end

  assign result = quo;
`endif

endmodule
