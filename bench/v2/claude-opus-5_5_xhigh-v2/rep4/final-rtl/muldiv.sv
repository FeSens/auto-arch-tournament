// rtl/muldiv.sv
//
// Multi-cycle RV32M unit (MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU). Keeps
// the multiplier and divider off the single-cycle EX path: operands are
// latched on the start cycle and every datapath stage is register-to-
// register.
//
// Handshake (driven by ex_stage):
//   start : only honoured when idle. Latches op/a/b (post-forwarding).
//   done  : registered, sticky until ack. result/a_lat/b_lat are valid
//           while done=1.
//   ack   : the M-op leaves EX this cycle; return to idle.
//
// Multiplier: ONE 33x33 signed product. Operands are sign- or zero-
//   extended per op (MUL/MULHU zero/zero, MULH sign/sign, MULHSU
//   sign/zero). Input regs (a_q/b_q + extension bits) -> product reg
//   (prod_q) -> hi/lo select mux on the output. Maps onto Gowin DSP with
//   registered inputs and registered product.
//   Latency: start cycle + 1 product cycle, done visible on the 3rd.
//
// Divider: radix-2 restoring divider on magnitudes, 1 quotient bit per
//   cycle (33-bit subtract), then a sign-fix cycle. RV32M rules fall out
//   naturally from the magnitude algorithm:
//     x / 0           -> quotient all ones (quotient sign-fix suppressed)
//     x % 0           -> remainder = |x|, sign of dividend -> x
//     INT_MIN / -1    -> |a|=2^31, |b|=1 -> q=2^31, signs equal -> INT_MIN
//     INT_MIN % -1    -> 0
//     remainder takes the sign of the dividend.
//   Latency: start + init + 32 iterations + sign-fix, done on the 36th.
//
// RISCV_FORMAL_ALTOPS: every op uses the riscv-formal substitute
//   formula ((a+b)^K / (a-b)^K) computed from the latched operands with
//   the same short latency as MUL, so the stall/handshake logic stays
//   within the formal BMC/liveness depth.
//
// Latency:        2 cycles (MUL*, ALTOPS) / 35 cycles (DIV*/REM*) of
//                 stall in EX.
// RVFI fields:    rd_wdata of M-ops (via EX/MEM alu_result); a_lat/b_lat
//                 feed rs1_rdata/rs2_rdata of M-ops.
module muldiv (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        ack,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        idle,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_lat,
  output logic [31:0] b_lat
);

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_CALC  = 3'd1;  // MUL product cycle / ALTOPS
  // Divider states are unused under RISCV_FORMAL_ALTOPS.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] S_DINIT = 3'd2;
  localparam logic [2:0] S_DITER = 3'd3;
  localparam logic [2:0] S_DFIX  = 3'd4;
  /* verilator lint_on UNUSEDPARAM */
  localparam logic [2:0] S_DONE  = 3'd5;

  logic [2:0]  state_q;
  logic        done_q;
  logic [4:0]  op_q;
  logic [31:0] a_q;
  logic [31:0] b_q;
  logic [31:0] res_q;
  logic        take;
  logic        is_div_op;

  assign take      = start && (state_q == S_IDLE);
  assign is_div_op = (op == ALU_DIV) || (op == ALU_DIVU) ||
                     (op == ALU_REM) || (op == ALU_REMU);

  // ── Control FSM ───────────────────────────────────────────────────────
`ifndef RISCV_FORMAL_ALTOPS
  logic [4:0] cnt_q;
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= S_IDLE;
      done_q  <= 1'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (start) begin
`ifdef RISCV_FORMAL_ALTOPS
            state_q <= S_CALC;
`else
            state_q <= is_div_op ? S_DINIT : S_CALC;
`endif
          end
        end
        S_CALC: begin
          state_q <= S_DONE;
          done_q  <= 1'b1;
        end
`ifndef RISCV_FORMAL_ALTOPS
        S_DINIT: state_q <= S_DITER;
        S_DITER: if (cnt_q == 5'd31) state_q <= S_DFIX;
        S_DFIX: begin
          state_q <= S_DONE;
          done_q  <= 1'b1;
        end
`endif
        S_DONE: begin
          if (ack) begin
            state_q <= S_IDLE;
            done_q  <= 1'b0;
          end
        end
        default: begin
          state_q <= S_IDLE;
          done_q  <= 1'b0;
        end
      endcase
    end
  end

  // ── Operand latch (start cycle) ───────────────────────────────────────
  always_ff @(posedge clock) begin
    if (take) begin
      op_q <= op;
      a_q  <= a;
      b_q  <= b;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  // ── ALTOPS stand-ins (riscv-formal §7.6), one calc cycle ─────────────
  // is_div_op only steers the real datapath.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_altops;
  assign unused_altops = is_div_op;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (state_q == S_CALC) begin
      case (op_q)
        ALU_MUL:    res_q <= (a_q + b_q) ^ 32'h5876063e;
        ALU_MULH:   res_q <= (a_q + b_q) ^ 32'hf6583fb7;
        ALU_MULHU:  res_q <= (a_q + b_q) ^ 32'h949ce5e8;
        ALU_MULHSU: res_q <= (a_q - b_q) ^ 32'hecfbe137;
        ALU_DIV:    res_q <= (a_q - b_q) ^ 32'h7f8529ec;
        ALU_DIVU:   res_q <= (a_q - b_q) ^ 32'h10e8fd70;
        ALU_REM:    res_q <= (a_q - b_q) ^ 32'h8da68fa5;
        ALU_REMU:   res_q <= (a_q - b_q) ^ 32'h3138d0e1;
        default:    res_q <= 32'b0;
      endcase
    end
  end

  assign result = res_q;
`else
  // ── Multiplier: 33x33 signed, registered in / registered product ─────
  logic               a_sx_q;     // bit 32 of the extended multiplicand
  logic               b_sx_q;     // bit 32 of the extended multiplier
  logic               prod_hi_q;  // select product[63:32]
  logic               is_mul_q;   // result comes from the product register
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  // prod_q[65:64] are pure sign extension of the 64-bit result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod_q;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (take) begin
      a_sx_q    <= a[31] && (op == ALU_MULH || op == ALU_MULHSU);
      b_sx_q    <= b[31] && (op == ALU_MULH);
      prod_hi_q <= (op != ALU_MUL);
      is_mul_q  <= !is_div_op;
    end
  end

  assign mul_a = {a_sx_q, a_q};
  assign mul_b = {b_sx_q, b_q};

  // Free-running product register: operands only change on `take`, so
  // prod_q is stable from the cycle after S_CALC until the next start.
  // Both operands signed: the product is evaluated at the 66-bit LHS
  // width with sign extension (a plain 33x33 signed multiply).
  /* verilator lint_off WIDTHEXPAND */
  always_ff @(posedge clock) begin
    prod_q <= mul_a * mul_b;
  end
  /* verilator lint_on WIDTHEXPAND */

  // ── Divider: radix-2 restoring on magnitudes ─────────────────────────
  logic [31:0] quo_q;   // dividend magnitude shifting out / quotient in
  logic [31:0] rem_q;   // partial remainder
  logic [31:0] dvs_q;   // divisor magnitude
  logic [32:0] diff;
  logic        div_signed;
  logic        neg_quo;
  logic        neg_rem;

  always_comb begin
    diff       = {rem_q, quo_q[31]} - {1'b0, dvs_q};
    div_signed = (op_q == ALU_DIV) || (op_q == ALU_REM);
    // Division by zero: quotient stays all ones (no sign fix).
    neg_quo    = div_signed && (a_q[31] ^ b_q[31]) && (b_q != 32'b0);
    neg_rem    = div_signed && a_q[31];
  end

  always_ff @(posedge clock) begin
    case (state_q)
      S_DINIT: begin
        quo_q <= (div_signed && a_q[31]) ? (32'd0 - a_q) : a_q;
        dvs_q <= (div_signed && b_q[31]) ? (32'd0 - b_q) : b_q;
        rem_q <= 32'd0;
        cnt_q <= 5'd0;
      end
      S_DITER: begin
        if (!diff[32]) begin
          rem_q <= diff[31:0];
          quo_q <= {quo_q[30:0], 1'b1};
        end else begin
          rem_q <= {rem_q[30:0], quo_q[31]};
          quo_q <= {quo_q[30:0], 1'b0};
        end
        cnt_q <= cnt_q + 5'd1;
      end
      S_DFIX: begin
        if (op_q == ALU_DIV || op_q == ALU_DIVU)
          res_q <= neg_quo ? (32'd0 - quo_q) : quo_q;
        else
          res_q <= neg_rem ? (32'd0 - rem_q) : rem_q;
      end
      default: ;
    endcase
  end

  assign result = is_mul_q ? (prod_hi_q ? prod_q[63:32] : prod_q[31:0])
                           : res_q;
`endif

  assign idle  = (state_q == S_IDLE);
  assign done  = done_q;
  assign a_lat = a_q;
  assign b_lat = b_q;

endmodule
