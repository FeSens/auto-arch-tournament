// rtl/muldiv.sv
//
// Sequential RV32M unit. Multiply / divide / remainder run here over
// several cycles while the M instruction waits in ID/EX (ex_stage raises
// ex_busy until `done`), so no `*`, `/` or `%` sits in the single-cycle
// forward -> ALU -> EX/MEM loop.
//
// Handshake:
//   start : level, "an M-op is in EX". Honoured only in S_IDLE; that cycle's
//           op/a/b (post-forward operands) are captured at the clock edge.
//   done  : high while the result is valid and waiting to be consumed.
//   ack   : EX/MEM captures the result this cycle -> back to S_IDLE.
//
// Multiplier: ONE 33x33 signed multiply. Operand sign bits are
// a[31]&a_signed / b[31]&b_signed. Operands are registered (DSP input
// registers); the product is read by EX/MEM in the next cycle, so a MUL*
// costs 1 extra cycle in EX. (`make timing`: operand reg -> DSP -> EX/MEM
// is not among the worst paths, so the product register was dropped.)
//
// Divider: radix-2 restoring on magnitudes, 1 bit/cycle:
//   capture (raw a/b + sign flags) -> S_DPRE (|a|, |b|) -> 32 x S_DRUN
//   -> S_DPOST (sign fix) -> S_DONE.
// RV32M corner cases fall out of the algorithm with one rule: negate the
// quotient only if the signs differ AND b != 0.
//   x / 0        -> all ones      x % 0        -> x
//   INT_MIN / -1 -> INT_MIN       INT_MIN % -1 -> 0
//
// RISCV_FORMAL_ALTOPS: same FSM and handshake, but every M-op takes the
// multiplier's path (capture -> S_DONE, fixed 1 extra cycle) and the result
// is riscv-formal's ALTOPS stand-in computed from the captured operands.
// A 35-cycle divide could not retire inside the 20-step BMC window. Real
// arithmetic and real divide latency are covered by test_muldiv.py, cosim
// and `make formal-deep`.
//
// Latency:        MUL* 1 extra cycle; DIV*/REM* 35 extra cycles.
// RVFI fields:    feeds rd_wdata of every M-extension instruction.
module muldiv (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        ack,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_DONE  = 3'd2;
`ifndef RISCV_FORMAL_ALTOPS
  localparam logic [2:0] S_DPRE  = 3'd3;
  localparam logic [2:0] S_DRUN  = 3'd4;
  localparam logic [2:0] S_DPOST = 3'd5;
`endif

  logic [2:0] state_q;
  logic       capture;

  assign capture = (state_q == S_IDLE) && start;
  assign done    = (state_q == S_DONE);

`ifdef RISCV_FORMAL_ALTOPS
  // ── ALTOPS: fixed 1-extra-cycle latency for every M-op ────────────────
  logic [4:0]  op_q;
  logic [31:0] a_q;
  logic [31:0] b_q;
  logic [31:0] alt_d;

  always_comb begin
    case (op_q)
      ALU_MUL:    alt_d = (a_q + b_q) ^ 32'h5876063e;
      ALU_MULH:   alt_d = (a_q + b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_d = (a_q + b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_d = (a_q - b_q) ^ 32'hecfbe137;
      ALU_DIV:    alt_d = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU:   alt_d = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:    alt_d = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU:   alt_d = (a_q - b_q) ^ 32'h3138d0e1;
      default:    alt_d = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= S_IDLE;
    end else begin
      case (state_q)
        S_IDLE:  if (start) state_q <= S_DONE;
        S_DONE:  if (ack)   state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (capture) begin
      op_q <= op;
      a_q  <= a;
      b_q  <= b;
    end
  end

  assign result = alt_d;

`else
  // ── Real arithmetic ───────────────────────────────────────────────────
  logic op_is_div;      // DIV / DIVU / REM / REMU
  logic op_is_rem;      // REM / REMU
  logic op_div_signed;  // DIV / REM
  logic op_a_signed;    // MULH / MULHSU
  logic op_b_signed;    // MULH

  always_comb begin
    op_is_div     = (op == ALU_DIV) || (op == ALU_DIVU)
                 || (op == ALU_REM) || (op == ALU_REMU);
    op_is_rem     = (op == ALU_REM) || (op == ALU_REMU);
    op_div_signed = (op == ALU_DIV) || (op == ALU_REM);
    op_a_signed   = (op == ALU_MULH) || (op == ALU_MULHSU);
    op_b_signed   = (op == ALU_MULH);
  end

  // Multiplier: registered operands -> 33x33 signed -> result mux. The
  // product is read by EX/MEM in the cycle after capture (S_DONE).
  logic signed [32:0] mul_a_q;
  logic signed [32:0] mul_b_q;
  // 33x33 signed product is 66 bits; bits [65:64] are sign copies.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_p_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic               mul_low_q;   // MUL (low half) vs MULH* (high half)

  always_ff @(posedge clock) begin
    if (capture) begin
      mul_a_q   <= $signed({a[31] & op_a_signed, a});
      mul_b_q   <= $signed({b[31] & op_b_signed, b});
      mul_low_q <= (op == ALU_MUL);
    end
  end

  assign mul_p_q = mul_a_q * mul_b_q;

  // Divider state.
  logic [31:0] quo_q;      // dividend, shifts out MSB-first; quotient shifts in
  logic [31:0] rem_q;      // partial remainder (always < divisor when b != 0)
  logic [31:0] dvs_q;      // divisor magnitude
  logic [4:0]  cnt_q;
  logic        a_neg_q;    // signed op and a < 0
  logic        b_neg_q;    // signed op and b < 0
  logic        b_zero_q;
  logic        is_div_q;
  logic        is_rem_q;

  // Trial subtract: {rem, next dividend bit} - divisor. The true difference
  // lies in (-2^32, 2^32), so bit 32 of the 33-bit result is its sign.
  logic [32:0] sub;
  assign sub = {rem_q, quo_q[31]} - {1'b0, dvs_q};

  // Sign fix (shared negator).
  logic [31:0] fix_val;
  logic        fix_neg;
  logic [31:0] fix_out;
  always_comb begin
    fix_val = is_rem_q ? rem_q : quo_q;
    fix_neg = is_rem_q ? a_neg_q : ((a_neg_q ^ b_neg_q) && !b_zero_q);
    fix_out = fix_neg ? (32'b0 - fix_val) : fix_val;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= S_IDLE;
    end else begin
      case (state_q)
        S_IDLE:  if (start) state_q <= op_is_div ? S_DPRE : S_DONE;
        S_DPRE:  state_q <= S_DRUN;
        S_DRUN:  if (cnt_q == 5'd31) state_q <= S_DPOST;
        S_DPOST: state_q <= S_DONE;
        S_DONE:  if (ack) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

  always_ff @(posedge clock) begin
    if (capture) begin
      quo_q    <= a;
      dvs_q    <= b;
      a_neg_q  <= op_div_signed && a[31];
      b_neg_q  <= op_div_signed && b[31];
      is_div_q <= op_is_div;
      is_rem_q <= op_is_rem;
    end else if (state_q == S_DPRE) begin
      // Magnitudes. INT_MIN negates to 0x8000_0000, which is the right
      // unsigned magnitude.
      quo_q    <= a_neg_q ? (32'b0 - quo_q) : quo_q;
      dvs_q    <= b_neg_q ? (32'b0 - dvs_q) : dvs_q;
      b_zero_q <= (dvs_q == 32'b0);
      rem_q    <= 32'b0;
      cnt_q    <= 5'd0;
    end else if (state_q == S_DRUN) begin
      if (!sub[32]) begin
        rem_q <= sub[31:0];
        quo_q <= {quo_q[30:0], 1'b1};
      end else begin
        rem_q <= {rem_q[30:0], quo_q[31]};
        quo_q <= {quo_q[30:0], 1'b0};
      end
      cnt_q <= cnt_q + 5'd1;
    end else if (state_q == S_DPOST) begin
      quo_q <= fix_out;   // final DIV*/REM* result lives in quo_q
    end
  end

  assign result = is_div_q  ? quo_q
                : mul_low_q ? mul_p_q[31:0]
                            : mul_p_q[63:32];
`endif

endmodule
