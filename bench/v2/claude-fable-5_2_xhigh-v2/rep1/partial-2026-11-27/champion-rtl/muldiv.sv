// rtl/muldiv.sv
//
// Sequential RV32M unit. Lives in EX; the pipeline stalls (ex_busy) while
// it runs.
//
// Handshake:
//   req    : a valid M op sits in ID/EX (level, stable until accepted).
//   start  : = idle && req. Operands a/b are sampled on this cycle only.
//   done   : result is valid; the unit parks here until `accept`.
//   accept : EX/MEM really captures the result this cycle (!dmem stall).
//
// f3 is the instruction's funct3 (stable while the op is held in ID/EX):
//   000 MUL  001 MULH  010 MULHSU  011 MULHU
//   100 DIV  101 DIVU  110 REM     111 REMU
//
// Multiplier: operands are registered as 33-bit sign/zero-extended values
// on the start cycle, one 33x33 signed product serves all four MUL ops.
// MUL_PIPE=0: 2 cycles in EX (product combinational from the operand regs).
// MUL_PIPE=1: 3 cycles in EX (product registered too).
//
// Divider: radix-2 restoring, one quotient bit per cycle on absolute
// values; sign fix-up on the done cycle. 34 cycles in EX.
//   x / 0        -> quotient all ones (negation suppressed), remainder = x
//   INT_MIN / -1 -> q = 0x80000000, r = 0 (falls out of the unsigned path)
//
// Under RISCV_FORMAL_ALTOPS the same start/done/accept handshake is kept
// but the result is the riscv-formal ALTOPS formula with a fixed 2-cycle
// latency, so every check retires inside the BMC window.
//
// Latency:        MUL 2 (or 3) cycles, DIV/REM 34 cycles, +dmem stall.
// RVFI fields:    feeds rd_wdata for the M-extension instructions.
module muldiv #(
  parameter integer MUL_PIPE = 0
) (
  input  logic        clock,
  input  logic        reset,
  input  logic        req,
  input  logic        accept,
  input  logic [2:0]  f3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        start,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_DIV  = 2'd1;
  localparam logic [1:0] S_MUL  = 2'd2;
  localparam logic [1:0] S_DONE = 2'd3;

  logic [1:0] state;

  assign start = (state == S_IDLE) && req;
  assign done  = (state == S_DONE);

`ifdef RISCV_FORMAL_ALTOPS
  // ── Formal stand-in: same handshake, ALTOPS formulas ──────────────────
  logic [31:0] a_q;
  logic [31:0] b_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:  if (req)    state <= S_DONE;
        S_DONE:  if (accept) state <= S_IDLE;
        default:             state <= S_IDLE;
      endcase
    end
    if (start) begin
      a_q <= a;
      b_q <= b;
    end
  end

  always_comb begin
    case (f3)
      3'b000:  result = (a_q + b_q) ^ 32'h5876063e; // MUL
      3'b001:  result = (a_q + b_q) ^ 32'hf6583fb7; // MULH
      3'b010:  result = (a_q - b_q) ^ 32'hecfbe137; // MULHSU
      3'b011:  result = (a_q + b_q) ^ 32'h949ce5e8; // MULHU
      3'b100:  result = (a_q - b_q) ^ 32'h7f8529ec; // DIV
      3'b101:  result = (a_q - b_q) ^ 32'h10e8fd70; // DIVU
      3'b110:  result = (a_q - b_q) ^ 32'h8da68fa5; // REM
      default: result = (a_q - b_q) ^ 32'h3138d0e1; // REMU
    endcase
  end
`else
  // ── Multiplier ────────────────────────────────────────────────────────
  logic               mul_a_sgn;
  logic               mul_b_sgn;
  logic signed [32:0] ma_q;
  logic signed [32:0] mb_q;
  // prod[65:64] are sign copies; never read.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        [63:0] prod_q;
  logic        [63:0] prod_sel;
  logic        [31:0] mul_res;

  assign mul_a_sgn = (f3[1:0] == 2'b01) || (f3[1:0] == 2'b10); // MULH, MULHSU
  assign mul_b_sgn = (f3[1:0] == 2'b01);                       // MULH

  /* verilator lint_off WIDTHEXPAND */
  assign prod = ma_q * mb_q;
  /* verilator lint_on WIDTHEXPAND */

  assign prod_sel = (MUL_PIPE != 0) ? prod_q : prod[63:0];
  assign mul_res  = (f3[1:0] == 2'b00) ? prod_sel[31:0] : prod_sel[63:32];

  // ── Divider ───────────────────────────────────────────────────────────
  logic        div_sgn;
  logic        a_neg;
  logic        b_neg;
  logic [31:0] a_abs;
  logic [31:0] b_abs;

  logic [31:0] quo_q;      // dividend shifts out of the top, quotient in
  logic [31:0] rem_q;
  logic [31:0] dvs_q;
  logic [4:0]  cnt_q;
  logic        neg_q_q;    // signs differ (quotient negation, unless /0)
  logic        neg_r_q;    // dividend negative (remainder negation)

  logic [32:0] rem_sh;
  // diff[32] is always 0 when the subtraction does not borrow.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] q_fix;
  logic [31:0] r_fix;
  logic [31:0] div_res;

  assign div_sgn = !f3[0];                 // DIV / REM are signed
  assign a_neg   = div_sgn && a[31];
  assign b_neg   = div_sgn && b[31];
  assign a_abs   = a_neg ? (32'd0 - a) : a;
  assign b_abs   = b_neg ? (32'd0 - b) : b;

  assign rem_sh = {rem_q, quo_q[31]};
  assign diff   = {1'b0, rem_sh} - {2'b00, dvs_q};
  assign ge     = !diff[33];

  assign q_fix   = (neg_q_q && (dvs_q != 32'd0)) ? (32'd0 - quo_q) : quo_q;
  assign r_fix   = neg_r_q ? (32'd0 - rem_q) : rem_q;
  assign div_res = f3[1] ? r_fix : q_fix;

  assign result  = f3[2] ? div_res : mul_res;

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: begin
          if (req) begin
            if (f3[2])              state <= S_DIV;
            else if (MUL_PIPE != 0) state <= S_MUL;
            else                    state <= S_DONE;
          end
        end
        S_DIV:   if (cnt_q == 5'd31) state <= S_DONE;
        S_MUL:                       state <= S_DONE;
        default: if (accept)         state <= S_IDLE;   // S_DONE
      endcase
    end

    // Datapath registers (no reset needed: only read after a start).
    prod_q <= prod[63:0];

    if (start) begin
      ma_q    <= {mul_a_sgn & a[31], a};
      mb_q    <= {mul_b_sgn & b[31], b};
      quo_q   <= a_abs;
      rem_q   <= 32'd0;
      dvs_q   <= b_abs;
      cnt_q   <= 5'd0;
      neg_q_q <= div_sgn && (a[31] ^ b[31]);
      neg_r_q <= a_neg;
    end else if (state == S_DIV) begin
      rem_q <= ge ? diff[31:0] : rem_sh[31:0];
      quo_q <= {quo_q[30:0], ge};
      cnt_q <= cnt_q + 5'd1;
    end
  end
`endif

endmodule
