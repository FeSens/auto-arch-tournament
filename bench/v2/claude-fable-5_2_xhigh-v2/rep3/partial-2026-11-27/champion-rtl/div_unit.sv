// rtl/div_unit.sv
//
// Shared sequential radix-2 restoring divider for DIV/DIVU/REM/REMU.
//
// Handshake (all outputs are register-only functions):
//   start  : pulse on the first cycle the DIV/REM sits in EX. Latches the
//            RAW operands and the op flags; no arithmetic is done on the
//            (late, post-forward) operand inputs.
//   busy   : the divide is running (PREP / RUN / FIX).
//   done   : STICKY. `result` is valid and stays valid until `clear`.
//   clear  : the DIV/REM actually left EX (EX/MEM captured it).
//
// Real sequence (36 cycles in EX including the start and done cycles):
//   start -> PREP (absolute values, from registers)
//         -> 32 x RUN (one quotient bit per cycle: 33-bit subtract + mux)
//         -> FIX (sign correction, result into the quotient register)
//         -> DONE
//
// RV32M corner cases:
//   x / 0        : the restoring loop yields quotient = all ones and
//                  remainder = |dividend|; the quotient negate is
//                  suppressed for divisor == 0, the remainder takes the
//                  dividend's sign back -> quotient -1, remainder = x.
//   INT_MIN / -1 : |INT_MIN| = 2^31 unsigned, |−1| = 1, equal signs so no
//                  negate -> quotient 0x80000000, remainder 0.
//
// Under RISCV_FORMAL_ALTOPS the same handshake is kept, but the divide
// finishes in two cycles (start -> FIX -> DONE) and returns the
// riscv-formal stand-in (a - b) ^ <per-op constant> computed from the
// latched operands.
//
// Latency:        multi-cycle, see above.
// RVFI fields:    feeds rd_wdata for DIV/DIVU/REM/REMU (via the ALU mux).
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        clear,
  input  logic        op_signed,   // DIV / REM  (vs DIVU / REMU)
  input  logic        op_rem,      // REM / REMU (vs DIV / DIVU)
  input  logic [31:0] a,           // dividend (raw, post-forward rs1)
  input  logic [31:0] b,           // divisor  (raw, post-forward rs2)
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  // S_PREP / S_RUN are unused in the ALTOPS build.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_PREP = 3'd1;
  localparam logic [2:0] S_RUN  = 3'd2;
  localparam logic [2:0] S_FIX  = 3'd3;
  localparam logic [2:0] S_DONE = 3'd4;
  /* verilator lint_on UNUSEDPARAM */

  logic [2:0]  state;
  logic [31:0] quo;        // dividend -> quotient -> final result
  logic [31:0] dvs;        // divisor
  logic        signed_q;
  logic        rem_q;

  assign busy   = (state != S_IDLE) && (state != S_DONE);
  assign done   = (state == S_DONE);
  assign result = quo;

`ifdef RISCV_FORMAL_ALTOPS

  // ── ALTOPS: start -> FIX -> DONE ──────────────────────────────────────
  logic [31:0] alt_const;

  always_comb begin
    case ({rem_q, signed_q})
      2'b01:   alt_const = 32'h7f8529ec;  // DIV
      2'b00:   alt_const = 32'h10e8fd70;  // DIVU
      2'b11:   alt_const = 32'h8da68fa5;  // REM
      default: alt_const = 32'h3138d0e1;  // REMU
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state    <= S_IDLE;
      quo      <= 32'b0;
      dvs      <= 32'b0;
      signed_q <= 1'b0;
      rem_q    <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            quo      <= a;
            dvs      <= b;
            signed_q <= op_signed;
            rem_q    <= op_rem;
            state    <= S_FIX;
          end
        end
        S_FIX: begin
          quo   <= (quo - dvs) ^ alt_const;
          state <= S_DONE;
        end
        S_DONE: begin
          if (clear) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

`else

  // ── Real radix-2 restoring divider ────────────────────────────────────
  logic [31:0] rem;
  logic [4:0]  cnt;
  logic        neg_q;      // negate quotient in FIX
  logic        neg_r;      // negate remainder in FIX

  // One restoring step: shift {rem, quo} left by one, trial-subtract.
  // The partial remainder before step k+1 is the top k bits of the
  // dividend reduced by the divisor, i.e. < 2^k <= 2^31, so the shifted
  // value always fits in 32 bits and a 33-bit subtract gives the borrow.
  logic [31:0] sh;
  logic [32:0] diff;
  logic        ge;
  logic [31:0] fix_val;
  logic        fix_neg;

  always_comb begin
    sh      = {rem[30:0], quo[31]};
    diff    = {1'b0, sh} - {1'b0, dvs};
    ge      = !diff[32];
    fix_val = rem_q ? rem   : quo;
    fix_neg = rem_q ? neg_r : neg_q;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state    <= S_IDLE;
      quo      <= 32'b0;
      dvs      <= 32'b0;
      rem      <= 32'b0;
      cnt      <= 5'b0;
      signed_q <= 1'b0;
      rem_q    <= 1'b0;
      neg_q    <= 1'b0;
      neg_r    <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            quo      <= a;
            dvs      <= b;
            signed_q <= op_signed;
            rem_q    <= op_rem;
            state    <= S_PREP;
          end
        end
        S_PREP: begin
          // Absolute values and result signs, all from registers.
          quo   <= (signed_q && quo[31]) ? (32'b0 - quo) : quo;
          dvs   <= (signed_q && dvs[31]) ? (32'b0 - dvs) : dvs;
          neg_q <= signed_q && (quo[31] ^ dvs[31]) && (dvs != 32'b0);
          neg_r <= signed_q && quo[31];
          rem   <= 32'b0;
          cnt   <= 5'b0;
          state <= S_RUN;
        end
        S_RUN: begin
          rem <= ge ? diff[31:0] : sh;
          quo <= {quo[30:0], ge};
          cnt <= cnt + 5'd1;
          if (cnt == 5'd31) state <= S_FIX;
        end
        S_FIX: begin
          quo   <= fix_neg ? (32'b0 - fix_val) : fix_val;
          state <= S_DONE;
        end
        S_DONE: begin
          if (clear) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

`endif

endmodule
