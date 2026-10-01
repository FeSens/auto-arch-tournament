// rtl/divider.sv
//
// Iterative RV32M divider (DIV / DIVU / REM / REMU). Radix-2 restoring
// division on unsigned magnitudes, one quotient bit per cycle, with a sign
// fix-up on the way out. Replaces the fully combinational `/` and `%` that
// used to sit in the ALU and dominated the EX critical path.
//
// Handshake (driven from ex_stage):
//   idle  : `start` is sampled; on start the operands are latched and the
//           unit goes busy. Later changes of a/b/op are ignored.
//   busy  : 32 iterations (real arithmetic) / 0 iterations (ALTOPS).
//   done  : `result` is valid and held until `ack`, then back to idle.
//
// RV32M corner cases fall out of the plain algorithm:
//   x / 0       : quo = 0xFFFFFFFF, rem = |a|. q_neg is forced to 0 when
//                 b == 0, so DIV/DIVU -> -1 and REM/REMU -> a.
//   INT_MIN/-1  : |a| = 0x80000000, |b| = 1 -> quo = 0x80000000 (q_neg = 0
//                 since both signs are set), rem = 0.
//
// Under RISCV_FORMAL_ALTOPS the same handshake finishes one cycle after
// start and returns the riscv-formal stand-in (a - b) ^ const from the
// latched operands, so the multi-cycle stall/bypass logic is still proved.
//
// Latency:        real: start cycle + 32 iterations + done cycle.
//                 ALTOPS: start cycle + done cycle.
// RVFI fields:    feeds rd_wdata for DIV/DIVU/REM/REMU (via EX/MEM).
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,      // a div is in EX; sampled only when idle
  input  logic        ack,        // result consumed (EX/MEM advanced)
  input  logic        is_signed,  // DIV / REM
  input  logic        is_rem,     // REM / REMU
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        idle,
  output logic        done,
  output logic [31:0] result
);

  logic run_q;
  logic done_q;

  assign idle = !run_q && !done_q;
  assign done = done_q;

`ifdef RISCV_FORMAL_ALTOPS
  // ── ALTOPS stand-in: same handshake, done one cycle after start ───────
  logic [31:0] a_q;
  logic [31:0] b_q;
  logic        is_signed_q;
  logic        is_rem_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      run_q  <= 1'b0;
      done_q <= 1'b0;
    end else if (idle) begin
      if (start) done_q <= 1'b1;
    end else if (ack) begin
      done_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (idle && start) begin
      a_q         <= a;
      b_q         <= b;
      is_signed_q <= is_signed;
      is_rem_q    <= is_rem;
    end
  end

  always_comb begin
    case ({is_rem_q, is_signed_q})
      2'b01:   result = (a_q - b_q) ^ 32'h7f8529ec;  // DIV
      2'b00:   result = (a_q - b_q) ^ 32'h10e8fd70;  // DIVU
      2'b11:   result = (a_q - b_q) ^ 32'h8da68fa5;  // REM
      default: result = (a_q - b_q) ^ 32'h3138d0e1;  // REMU
    endcase
  end
`else
  // ── Radix-2 restoring divider ─────────────────────────────────────────
  logic [4:0]  cnt_q;
  logic [31:0] rem_q;     // partial remainder
  logic [31:0] quo_q;     // dividend shifts out of the top, quotient in
  logic [31:0] dvs_q;     // |divisor|
  logic        q_neg_q;
  logic        r_neg_q;
  logic        is_rem_q;

  logic        a_neg;
  logic        b_neg;
  logic [31:0] a_mag;
  logic [31:0] b_mag;
  logic [32:0] shifted;
  // diff[32] is 0 whenever the trial subtract is kept (new rem < |b|).
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] sel;
  logic        neg;

  always_comb begin
    a_neg   = is_signed && a[31];
    b_neg   = is_signed && b[31];
    a_mag   = a_neg ? (32'b0 - a) : a;
    b_mag   = b_neg ? (32'b0 - b) : b;

    shifted = {rem_q, quo_q[31]};
    diff    = {1'b0, shifted} - {2'b0, dvs_q};
    ge      = !diff[33];

    sel     = is_rem_q ? rem_q   : quo_q;
    neg     = is_rem_q ? r_neg_q : q_neg_q;
    result  = neg ? (32'b0 - sel) : sel;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      run_q  <= 1'b0;
      done_q <= 1'b0;
    end else if (idle) begin
      if (start) run_q <= 1'b1;
    end else if (run_q) begin
      if (cnt_q == 5'd31) begin
        run_q  <= 1'b0;
        done_q <= 1'b1;
      end
    end else if (ack) begin
      done_q <= 1'b0;
    end
  end

  always_ff @(posedge clock) begin
    if (idle && start) begin
      cnt_q    <= 5'd0;
      rem_q    <= 32'b0;
      quo_q    <= a_mag;
      dvs_q    <= b_mag;
      q_neg_q  <= (a_neg ^ b_neg) && (b != 32'b0);
      r_neg_q  <= a_neg;
      is_rem_q <= is_rem;
    end else if (run_q) begin
      cnt_q <= cnt_q + 5'd1;
      rem_q <= ge ? diff[31:0] : shifted[31:0];
      quo_q <= {quo_q[30:0], ge};
    end
  end
`endif

endmodule
