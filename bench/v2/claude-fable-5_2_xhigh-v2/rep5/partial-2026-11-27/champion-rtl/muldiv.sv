// rtl/muldiv.sv
//
// Sequential RV32M unit. The M-op waits in EX (ID/EX held, EX/MEM bubbled)
// until `done`; the result is then captured into EX/MEM.
//
// Handshake:
//   start  : level, an M-op sits in ID/EX (held high until it leaves EX).
//   accept : EX/MEM captures this cycle (no dmem stall).
//   done   : `result` is valid this cycle; held until `accept`.
//
// The post-forwarding operands are latched on the first EX cycle (state
// IDLE) because the forwarding sources drain out of EX/MEM / MEM/WB while
// the op waits. `a_lat` / `b_lat` export the latched operands (RVFI
// rs1_rdata / rs2_rdata of the M-op).
//
// op = funct3:  000 MUL  001 MULH  010 MULHSU  011 MULHU
//               100 DIV  101 DIVU  110 REM     111 REMU
//
// Multiplier: ONE 33x33 signed multiply; operands are sign/zero-extended
//   to 33 bits per op and registered on the first EX cycle, the product
//   (hi/lo select) is consumed on the second: MUL = 2 EX cycles.
// Divider: radix-2 restoring on |a|,|b|, 32 iterations, sign fix-up.
//   x/0 -> all ones (quotient not negated when b==0), rem by 0 -> dividend,
//   INT_MIN/-1 -> INT_MIN, rem 0 (falls out of the |.| arithmetic).
//   DIV/REM = 36 EX cycles.
//
// Under RISCV_FORMAL_ALTOPS every op returns the riscv-formal XOR stand-in
// through the same handshake (2 EX cycles), so the BMC still exercises the
// M-op stall / operand-latch / forwarding behaviour.
//
// Latency:        MUL* 2 cycles, DIV*/REM* 36 cycles (in EX).
// RVFI fields:    rd_wdata of M-ops; rs1_rdata / rs2_rdata via a_lat/b_lat.
module muldiv (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [2:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_lat,
  output logic [31:0] b_lat
);

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_MUL  = 3'd1;   // product (or ALTOPS value) valid
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] S_INIT = 3'd2;   // load |a|, |b|
  localparam logic [2:0] S_DIV  = 3'd3;   // 32 restoring iterations
  localparam logic [2:0] S_FIX  = 3'd4;   // sign fix-up into res_q
  localparam logic [2:0] S_DONE = 3'd5;   // res_q valid
  /* verilator lint_on UNUSEDPARAM */

  logic [2:0]  state;

  // 33-bit operand latches: bit 32 is the sign extension chosen per op.
  logic [32:0] a_q;
  logic [32:0] b_q;

  logic        is_div;
  logic        a_signed;
  logic        b_signed;
  always_comb begin
    is_div   = op[2];
    // MUL (low half) is sign-agnostic; treat it like MULH.
    a_signed = is_div ? !op[0] : (op[1:0] != 2'b11);
    b_signed = is_div ? !op[0] : !op[1];
  end

  assign a_lat = a_q[31:0];
  assign b_lat = b_q[31:0];

  logic [31:0] mul_res;
  logic [31:0] res_q;

`ifdef RISCV_FORMAL_ALTOPS
  // ── riscv-formal ALTOPS stand-ins ─────────────────────────────────────
  always_comb begin
    case (op)
      3'd0:    mul_res = (a_q[31:0] + b_q[31:0]) ^ 32'h5876063e; // MUL
      3'd1:    mul_res = (a_q[31:0] + b_q[31:0]) ^ 32'hf6583fb7; // MULH
      3'd2:    mul_res = (a_q[31:0] - b_q[31:0]) ^ 32'hecfbe137; // MULHSU
      3'd3:    mul_res = (a_q[31:0] + b_q[31:0]) ^ 32'h949ce5e8; // MULHU
      3'd4:    mul_res = (a_q[31:0] - b_q[31:0]) ^ 32'h7f8529ec; // DIV
      3'd5:    mul_res = (a_q[31:0] - b_q[31:0]) ^ 32'h10e8fd70; // DIVU
      3'd6:    mul_res = (a_q[31:0] - b_q[31:0]) ^ 32'h8da68fa5; // REM
      default: mul_res = (a_q[31:0] - b_q[31:0]) ^ 32'h3138d0e1; // REMU
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:  if (start)  state <= S_MUL;
        default: if (accept) state <= S_IDLE;
      endcase
    end
    if (state == S_IDLE && start) begin
      a_q <= {a[31] & a_signed, a};
      b_q <= {b[31] & b_signed, b};
    end
    res_q <= 32'b0;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_altops;
  assign unused_altops = is_div;
  /* verilator lint_on UNUSEDSIGNAL */
`else
  // ── Multiplier: one 33x33 signed multiply, registered operands ────────
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;   // bits 65:64 are sign copies
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    prod    = $signed(a_q) * $signed(b_q);
    mul_res = (op[1:0] == 2'b00) ? prod[31:0] : prod[63:32];
  end

  // ── Divider: shared radix-2 restoring datapath ────────────────────────
  logic [31:0] rem_q;
  logic [31:0] quo_q;
  logic [31:0] dvs_q;
  logic [4:0]  cnt_q;

  logic [32:0] sh;       // {rem, next dividend bit}
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;     // bit 33 = borrow; bit 32 is always 0 when no borrow
  /* verilator lint_on UNUSEDSIGNAL */
  logic        b_zero;
  logic        quo_neg;
  always_comb begin
    sh      = {rem_q, quo_q[31]};
    diff    = {1'b0, sh} - {2'b0, dvs_q};
    b_zero  = (b_q[31:0] == 32'b0);
    // Quotient is negative when the signs differ — except for x/0, which
    // must stay all-ones.
    quo_neg = (a_q[32] ^ b_q[32]) && !b_zero;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:  if (start)            state <= is_div ? S_INIT : S_MUL;
        S_INIT:                        state <= S_DIV;
        S_DIV:   if (cnt_q == 5'd31)   state <= S_FIX;
        S_FIX:                         state <= S_DONE;
        default: if (accept)           state <= S_IDLE;   // S_MUL / S_DONE
      endcase
    end

    if (state == S_IDLE && start) begin
      a_q <= {a[31] & a_signed, a};
      b_q <= {b[31] & b_signed, b};
    end

    if (state == S_INIT) begin
      rem_q <= 32'b0;
      quo_q <= a_q[32] ? (32'b0 - a_q[31:0]) : a_q[31:0];
      dvs_q <= b_q[32] ? (32'b0 - b_q[31:0]) : b_q[31:0];
      cnt_q <= 5'd0;
    end else if (state == S_DIV) begin
      if (!diff[33]) begin
        rem_q <= diff[31:0];
        quo_q <= {quo_q[30:0], 1'b1};
      end else begin
        rem_q <= sh[31:0];
        quo_q <= {quo_q[30:0], 1'b0};
      end
      cnt_q <= cnt_q + 5'd1;
    end

    if (state == S_FIX) begin
      if (op[1]) res_q <= a_q[32] ? (32'b0 - rem_q) : rem_q;   // REM / REMU
      else       res_q <= quo_neg ? (32'b0 - quo_q) : quo_q;   // DIV / DIVU
    end
  end
`endif

  always_comb begin
    done   = (state == S_MUL) || (state == S_DONE);
    result = (state == S_MUL) ? mul_res : res_q;
  end

endmodule
