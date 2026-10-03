// rtl/mdu.sv
//
// Sequential RV32M unit (MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU).
//
// The unit is NOT part of the single-cycle EX datapath: every arithmetic
// stage reads only registers, so nothing combinational chains from the
// EX forwarding network into the multiplier or divider.
//
// Handshake (driven by ex_stage):
//   active : an M-op (ID/EX.valid && alu_op >= ALU_MUL) occupies EX. It
//            stays asserted until the op leaves EX.
//   op/a/b : ID/EX alu_op and the forward-resolved rs1/rs2. They are only
//            sampled while the unit is idle (cycle 0 of the op); the
//            forwarding sources are gone by the next cycle.
//   hold   : EX/MEM is frozen (dmem stall). `done` is kept until the
//            result is accepted (done && !hold), then the unit goes idle.
//   busy   : a_cap/b_cap hold the operands of the op in EX (state != IDLE).
//   done   : `result` is valid this cycle. Pure function of the state reg.
//
// Timing (cycles the op spends in EX, including the capture cycle 0):
//   MUL*      : 3  (capture, register 4 partial products, sum -> done)
//   DIV*/REM* : 35 (capture, abs, 32 restoring-divide steps, sign fix -> done)
//   ALTOPS    : 2  (capture, done)
//
// Multiply: operands are extended to 33-bit signed (sign bit only for the
// operand the op treats as signed), split into a 17-bit signed high part
// and a 16-bit unsigned low part (zero-extended to a nonnegative 17-bit
// signed), so all four partial products are 17x17 signed (one MULT18X18).
//
// Divide: radix-2 restoring divider on the operand magnitudes, followed by
// the sign fix. Division by zero falls out of the algorithm (quotient all
// ones, remainder = |dividend|, negated back to the dividend); the
// quotient negation is suppressed when the divisor is zero. INT_MIN / -1
// also falls out (|INT_MIN| / 1 negated back to INT_MIN, remainder 0).
//
// RISCV_FORMAL_ALTOPS: the arithmetic is replaced by the riscv-formal
// (a+b)^const / (a-b)^const stand-ins, computed on the captured operands.
//
// Latency:        multi-cycle (see above).
// RVFI fields:    feeds rd_wdata of M-ops via EX/MEM.alu_result; a_cap/b_cap
//                 feed rs1_rdata/rs2_rdata of the op while it stalls in EX.
module mdu (
  input  logic        clock,
  input  logic        reset,
  input  logic        active,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        hold,
  output logic        busy,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_cap,
  output logic [31:0] b_cap
);

  // S_MUL / S_DIV_INIT / S_DIV are unused under RISCV_FORMAL_ALTOPS.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] S_IDLE     = 3'd0;
  localparam logic [2:0] S_MUL      = 3'd1;  // register the partial products
  localparam logic [2:0] S_DIV_INIT = 3'd2;  // operand magnitudes
  localparam logic [2:0] S_DIV      = 3'd3;  // 32 restoring-divide steps
  localparam logic [2:0] S_DONE     = 3'd4;  // result valid, wait for accept
  /* verilator lint_on UNUSEDPARAM */

  logic [2:0]  state;
  logic [4:0]  op_q;
  logic [31:0] a_q;
  logic [31:0] b_q;

  assign busy  = (state != S_IDLE);
  assign done  = (state == S_DONE);
  assign a_cap = a_q;
  assign b_cap = b_q;

  // Operands/op are sampled every idle cycle (no dependence on `active`
  // keeps the capture enable off the forwarding path).
  always_ff @(posedge clock) begin
    if (state == S_IDLE) begin
      op_q <= op;
      a_q  <= a;
      b_q  <= b;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  // ── riscv-formal stand-ins ────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset)                            state <= S_IDLE;
    else if (state == S_IDLE && active)   state <= S_DONE;
    else if (state == S_DONE && !hold)    state <= S_IDLE;
  end

  always_comb begin
    case (op_q)
      ALU_MUL:    result = (a_q + b_q) ^ 32'h5876063e;
      ALU_MULH:   result = (a_q + b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  result = (a_q + b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: result = (a_q - b_q) ^ 32'hecfbe137;
      ALU_DIV:    result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU:   result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:    result = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU:   result = (a_q - b_q) ^ 32'h3138d0e1;
      default:    result = 32'b0;
    endcase
  end
`else
  // ── Op decode (registered op) ─────────────────────────────────────────
  logic a_signed_mul;   // multiplicand a treated as signed
  logic b_signed_mul;   // multiplier b treated as signed
  logic mul_high;       // select the high word of the product
  logic div_signed;
  logic is_rem;
  logic is_div;

  always_comb begin
    // MUL's low word is independent of operand signedness.
    a_signed_mul = (op_q == ALU_MULH) || (op_q == ALU_MULHSU);
    b_signed_mul = (op_q == ALU_MULH);
    mul_high     = (op_q != ALU_MUL);
    div_signed   = (op_q == ALU_DIV) || (op_q == ALU_REM);
    is_rem       = (op_q == ALU_REM) || (op_q == ALU_REMU);
    is_div       = (op_q >= ALU_DIV);
  end

  // ── Multiplier: four 17x17 signed partial products ────────────────────
  logic signed [16:0] a_hi, a_lo, b_hi, b_lo;
  logic signed [33:0] pp_ll, pp_lh, pp_hl, pp_hh;

  always_comb begin
    a_hi = {a_signed_mul & a_q[31], a_q[31:16]};
    a_lo = {1'b0, a_q[15:0]};
    b_hi = {b_signed_mul & b_q[31], b_q[31:16]};
    b_lo = {1'b0, b_q[15:0]};
  end

  always_ff @(posedge clock) begin
    if (state == S_MUL) begin
      pp_ll <= a_lo * b_lo;
      pp_lh <= a_lo * b_hi;
      pp_hl <= a_hi * b_lo;
      pp_hh <= a_hi * b_hi;
    end
  end

  // product = ll + ((lh + hl) << 16) + (hh << 32), modulo 2^64. pp_ll is
  // always nonnegative (unsigned 16x16); the upper bits of pp_hh fall off.
  logic signed [34:0] pp_mid;
  logic        [63:0] product;
  logic        [31:0] mul_res;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [33:0] pp_unused;   // keeps the pp_hh[33:32] drop explicit
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    pp_unused = pp_hh;
    pp_mid    = pp_lh + pp_hl;
    product   = {30'b0, pp_ll}
              + {{13{pp_mid[34]}}, pp_mid, 16'b0}
              + {pp_hh[31:0], 32'b0};
    mul_res   = mul_high ? product[63:32] : product[31:0];
  end

  // ── Divider: restoring, one quotient bit per cycle ────────────────────
  logic [31:0] num;       // dividend magnitude -> quotient (shifted in at LSB)
  logic [31:0] rem;       // partial remainder
  logic [31:0] den;       // divisor magnitude
  logic [4:0]  cnt;
  logic        neg_q;     // negate the quotient
  logic        neg_r;     // negate the remainder

  logic [31:0] a_abs, b_abs;
  logic [32:0] rem_sh;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] sub;       // sub[33] = borrow; sub[32] is always 0 when !borrow
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] q_res, r_res, div_res;

  always_comb begin
    a_abs  = (div_signed && a_q[31]) ? (32'b0 - a_q) : a_q;
    b_abs  = (div_signed && b_q[31]) ? (32'b0 - b_q) : b_q;

    rem_sh = {rem, num[31]};
    sub    = {1'b0, rem_sh} - {2'b0, den};
    ge     = !sub[33];

    q_res   = neg_q ? (32'b0 - num) : num;
    r_res   = neg_r ? (32'b0 - rem) : rem;
    div_res = is_rem ? r_res : q_res;
  end

  always_ff @(posedge clock) begin
    if (state == S_DIV_INIT) begin
      num   <= a_abs;
      den   <= b_abs;
      rem   <= 32'b0;
      cnt   <= 5'd0;
      neg_q <= div_signed && (a_q[31] ^ b_q[31]) && (b_q != 32'b0);
      neg_r <= div_signed && a_q[31];
    end else if (state == S_DIV) begin
      rem   <= ge ? sub[31:0] : rem_sh[31:0];
      num   <= {num[30:0], ge};
      cnt   <= cnt + 5'd1;
    end
  end

  assign result = is_div ? div_res : mul_res;

  // ── Control ───────────────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:     if (active) state <= (op >= ALU_DIV) ? S_DIV_INIT : S_MUL;
        S_MUL:      state <= S_DONE;
        S_DIV_INIT: state <= S_DIV;
        S_DIV:      if (cnt == 5'd31) state <= S_DONE;
        S_DONE:     if (!hold) state <= S_IDLE;
        default:    state <= S_IDLE;
      endcase
    end
  end
`endif

endmodule
