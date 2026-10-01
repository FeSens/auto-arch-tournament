// rtl/alu.sv
//
// RV32IM ALU. Every op except DIV/DIVU/REM/REMU is combinational. The
// multiplier is a single signed 33x33 product whose operand sign-extension
// bits are selected per op (MUL/MULHU: unsigned*unsigned, MULH:
// signed*signed, MULHSU: signed*unsigned).
//
// Division is a radix-2 restoring shift-subtract FSM (1 quotient bit per
// cycle) so the 32-bit array divider no longer sits on the EX critical
// path. Handshake:
//   div_start : EX holds a DIV* op whose result is not ready and the
//               divider is idle. op/a/b are latched this cycle.
//   div_busy  : iterating (or in the sign fix-up cycle).
//   div_done  : result is valid on `out` (for DIV* ops) and stays valid
//               until div_ack.
//   div_ack   : consumer has taken the result; clears div_done.
//
// Real arithmetic timeline: start (raw operand latch, no arithmetic) ->
// 1 prep cycle (conditional negate to sign-magnitude, from flops) ->
// 32 iterations -> 1 fix-up cycle (conditional negate of quotient /
// remainder) -> done. Keeping the start cycle arithmetic-free takes the
// negate ripple off the EX bypass path. RV32M special cases fall
// out of the datapath:
//   DIV/DIVU by 0   -> quotient all ones (neg_quo suppressed when b == 0)
//   REM/REMU by 0   -> dividend
//   DIV INT_MIN/-1  -> |q| = 0x80000000, negated = INT_MIN
//   REM INT_MIN/-1  -> 0
//
// Under RISCV_FORMAL_ALTOPS the result is (a - b) ^ const computed from
// the latched operands, through the same start -> fix-up -> done
// handshake (no iterations) so formal still exercises the stall path.
//
// Result select: `sel` is a registered one-hot result class (RS_* in
// core_pkg) decoded in ID; `out` is an AND-OR of the class results, split
// into two kept partial ORs so the slow DSP product joins last:
// fast_or (every non-multiply class) | mul_or (MULLO / MULHI).
// `op` only feeds the divider (sign / rem latch) and the ALTOPS stand-ins.
// `pre` is the ID-precomputed LUI / AUIPC / link value (RS_PRE).
//
// Latency:        combinational for non-divide ops; DIV* = 35 cycles
//                 from div_start to div_done (ALTOPS: 2).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic        clock,
  input  logic        reset,
  // op is only decoded for the divider and the ALTOPS MULH* stand-ins.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [4:0]  op,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [RS_W-1:0] sel,
  input  logic        shift_arith,
  input  logic        a_signed,
  input  logic        b_signed,
  input  logic [31:0] pre,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        div_start,
  input  logic        div_ack,
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] out
);

  logic [4:0] shamt;

  // ── Merged multiplier ─────────────────────────────────────────────────
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  // Bits [65:64] of the 66-bit product are never read.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    mul_a    = $signed({a[31] & a_signed, a});
    mul_b    = $signed({b[31] & b_signed, b});
    /* verilator lint_off WIDTHEXPAND */
    prod     = mul_a * mul_b;
    /* verilator lint_on WIDTHEXPAND */
  end

  // ── Iterative divider ─────────────────────────────────────────────────
  logic        busy_q;
  logic        prep_q;
  logic        fix_q;
  logic        done_q;
  logic [4:0]  cnt_q;
  logic [31:0] rem_q;
  logic [31:0] quo_q;     // dividend -> quotient -> final result
  logic [31:0] dvs_q;
  logic        neg_quo_q;
  logic        neg_rem_q;   // sa: dividend negative (also the prep negate)
  logic        sb_q;        // divisor negative (prep negate only)
  logic        is_rem_q;
`ifdef RISCV_FORMAL_ALTOPS
  logic [1:0]  op_q;
`endif

  logic        div_signed;
  logic        sa;
  logic        sb;
  logic [32:0] shifted;
  // diff[32] is always 0 when diff[33] (borrow) is clear, since the
  // partial remainder stays below the divisor.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    div_signed = (op == ALU_DIV) || (op == ALU_REM);
    sa         = div_signed && a[31];
    sb         = div_signed && b[31];
    shifted    = {rem_q, quo_q[31]};
    diff       = {1'b0, shifted} - {2'b0, dvs_q};
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q    <= 1'b0;
      prep_q    <= 1'b0;
      fix_q     <= 1'b0;
      done_q    <= 1'b0;
      cnt_q     <= 5'd0;
      rem_q     <= 32'b0;
      quo_q     <= 32'b0;
      dvs_q     <= 32'b0;
      neg_quo_q <= 1'b0;
      neg_rem_q <= 1'b0;
      sb_q      <= 1'b0;
      is_rem_q  <= 1'b0;
`ifdef RISCV_FORMAL_ALTOPS
      op_q      <= 2'b0;
`endif
    end else if (div_start) begin
      busy_q    <= 1'b1;
      done_q    <= 1'b0;
      cnt_q     <= 5'd0;
      rem_q     <= 32'b0;
      is_rem_q  <= (op == ALU_REM) || (op == ALU_REMU);
      quo_q     <= a;
      dvs_q     <= b;
`ifdef RISCV_FORMAL_ALTOPS
      prep_q    <= 1'b0;
      fix_q     <= 1'b1;
      neg_quo_q <= 1'b0;
      neg_rem_q <= 1'b0;
      sb_q      <= 1'b0;
      op_q      <= (op == ALU_DIV)  ? 2'd0 :
                   (op == ALU_DIVU) ? 2'd1 :
                   (op == ALU_REM)  ? 2'd2 : 2'd3;
`else
      // Raw operand latch only; the negates happen in the prep cycle.
      prep_q    <= 1'b1;
      fix_q     <= 1'b0;
      neg_rem_q <= sa;
      sb_q      <= sb;
`endif
    end else if (prep_q) begin
      // Sign-magnitude conversion from flops. b != 0 iff |b| != 0.
      quo_q     <= neg_rem_q ? (32'd0 - quo_q) : quo_q;
      dvs_q     <= sb_q      ? (32'd0 - dvs_q) : dvs_q;
      neg_quo_q <= (neg_rem_q ^ sb_q) && (dvs_q != 32'b0);
      prep_q    <= 1'b0;
    end else if (fix_q) begin
`ifdef RISCV_FORMAL_ALTOPS
      case (op_q)
        2'd0:    quo_q <= (quo_q - dvs_q) ^ 32'h7f8529ec;
        2'd1:    quo_q <= (quo_q - dvs_q) ^ 32'h10e8fd70;
        2'd2:    quo_q <= (quo_q - dvs_q) ^ 32'h8da68fa5;
        default: quo_q <= (quo_q - dvs_q) ^ 32'h3138d0e1;
      endcase
`else
      if (is_rem_q)
        quo_q <= neg_rem_q ? (32'd0 - rem_q) : rem_q;
      else
        quo_q <= neg_quo_q ? (32'd0 - quo_q) : quo_q;
`endif
      fix_q  <= 1'b0;
      busy_q <= 1'b0;
      done_q <= 1'b1;
    end else if (busy_q) begin
      // One restoring step: shift {rem, quo} left, try subtracting.
      if (!diff[33]) begin
        rem_q <= diff[31:0];
        quo_q <= {quo_q[30:0], 1'b1};
      end else begin
        rem_q <= shifted[31:0];
        quo_q <= {quo_q[30:0], 1'b0};
      end
      cnt_q <= cnt_q + 5'd1;
      if (cnt_q == 5'd31) fix_q <= 1'b1;
    end else if (div_ack) begin
      done_q <= 1'b0;
    end
  end

  assign div_busy = busy_q;
  assign div_done = done_q;

  // ── One-hot result AND-OR ─────────────────────────────────────────────
  // Kept partial ORs: the DSP product passes only the mul_or LUT and the
  // final OR instead of the full depth of a collapsed 12-way tree.
  (* syn_keep = 1 *) logic [31:0] fast_or;
  (* syn_keep = 1 *) logic [31:0] mul_or;
  logic [31:0] add_res;
  logic [31:0] sub_res;
  logic        lt_s;
  logic        lt_u;
  logic [31:0] sll_res;
  // sr_ext[32] is the fill bit only.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr_ext;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] mul_lo;
  logic [31:0] mul_hi;

  always_comb begin
    shamt   = b[4:0];
    add_res = a + b;
    sub_res = a - b;
    lt_s    = $signed(a) < $signed(b);
    lt_u    = a < b;
    sll_res = a << shamt;
    sr_ext  = $unsigned($signed({shift_arith & a[31], a}) >>> shamt);

    // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
    // are substituted for tractable algebraic stand-ins so bitwuzla
    // can solve the BMC inside the 20-step depth budget. The same
    // substitution must appear in the riscv-formal spec (insn_*.v).
    // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
    // run the real arithmetic. DIV* read the divider's result register
    // in both modes (the ALTOPS formula is applied in the fix-up cycle).
`ifdef RISCV_FORMAL_ALTOPS
    mul_lo = (a + b) ^ 32'h5876063e;
    case (op)
      ALU_MULH:   mul_hi = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_hi = (a + b) ^ 32'h949ce5e8;
      default:    mul_hi = (a - b) ^ 32'hecfbe137;   // ALU_MULHSU
    endcase
`else
    mul_lo = prod[31:0];
    mul_hi = prod[63:32];
`endif

    fast_or = ({32{sel[RS_ADD]}}   & add_res)
            | ({32{sel[RS_SUB]}}   & sub_res)
            | ({32{sel[RS_AND]}}   & (a & b))
            | ({32{sel[RS_OR]}}    & (a | b))
            | ({32{sel[RS_XOR]}}   & (a ^ b))
            | {31'b0, (sel[RS_SLT] & lt_s) | (sel[RS_SLTU] & lt_u)}
            | ({32{sel[RS_SLL]}}   & sll_res)
            | ({32{sel[RS_SR]}}    & sr_ext[31:0])
            | ({32{sel[RS_DIV]}}   & quo_q)
            | ({32{sel[RS_PRE]}}   & pre);
    mul_or  = ({32{sel[RS_MULLO]}} & mul_lo)
            | ({32{sel[RS_MULHI]}} & mul_hi);
    out     = fast_or | mul_or;
  end

endmodule
