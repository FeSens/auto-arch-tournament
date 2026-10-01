// rtl/divider.sv
//
// Sequential RV32M divider for DIV / DIVU / REM / REMU. Restoring radix-2,
// one quotient bit per cycle, kept off the single-cycle EX path.
//
// Handshake (driven by ex_stage):
//   req    : a DIV/DIVU/REM/REMU sits in ID/EX (registered ctrl.is_div).
//            Held high for the whole operation; the pipeline holds the
//            div in EX until the result is accepted.
//   accept : the EX/MEM register is enabled this cycle (!stall_ex_mem).
//   done   : result valid. Stays high (result held) until accept, so a
//            coincident dmem stall cannot lose it.
//   busy   : iterating (not idle, not done).
//
// Timeline (real arithmetic):
//   t0     : IDLE && req  -> latch |a|, |b|, signs, op       (start)
//   t1..32 : RUN, 32 iterations of a 33-bit trial subtract
//   t33    : FIX, sign fix-up written back into the quotient register
//   t34    : DONE, result presented, released on accept
//
// RV32M corner cases fall out of the unsigned algorithm:
//   x / 0         -> quo = all-ones, rem = |a|; the quotient negation is
//                    suppressed when b == 0, so DIV by 0 = -1 and REM by 0
//                    = a (remainder takes the dividend's sign).
//   INT_MIN / -1  -> |a| = 0x80000000, |b| = 1: quo = 0x80000000 (signs
//                    cancel, no negation), rem = 0.
//
// Under RISCV_FORMAL_ALTOPS the same FSM/handshake is used, but the
// start cycle latches the riscv-formal stand-in ((a-b) ^ const) and jumps
// straight to FIX, so the result is ready two cycles after start.
//
// Latency:        35 cycles in EX per divide (2+1 under ALTOPS).
// RVFI fields:    feeds rd_wdata for DIV/DIVU/REM/REMU via EX/MEM.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  localparam logic [1:0] S_IDLE = 2'd0;
  localparam logic [1:0] S_RUN  = 2'd1;
  localparam logic [1:0] S_FIX  = 2'd2;
  localparam logic [1:0] S_DONE = 2'd3;

  logic [1:0]  state;
  logic [4:0]  cnt;
  logic [31:0] rem_q;     // partial remainder (always < |b|)
  logic [31:0] quo_q;     // dividend shifting out / quotient shifting in
  logic [31:0] div_q;     // |b|
  logic        is_rem_q;
  logic        neg_q_q;   // negate quotient (signed, signs differ)
  logic        neg_r_q;   // negate remainder (signed, dividend negative)

  logic        start;
  logic        is_signed;
  logic        is_rem;

  // One restoring step: shift the next dividend bit into the remainder
  // and try to subtract the divisor.
  // diff[32] is dropped: rem < |b| so a non-negative diff fits 32 bits.
  logic [32:0] trial;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */

  // Sign fix-up.
  logic        fix_neg;
  logic [31:0] fix_src;
  logic [31:0] fix_val;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_val;
`endif

  always_comb begin
    start     = req && (state == S_IDLE);
    is_signed = (op == ALU_DIV) || (op == ALU_REM);
    is_rem    = (op == ALU_REM) || (op == ALU_REMU);

    trial = {rem_q, quo_q[31]};
    diff  = {1'b0, trial} - {2'b0, div_q};

    fix_src = is_rem_q ? rem_q : quo_q;
    fix_neg = is_rem_q ? neg_r_q : (neg_q_q && (div_q != 32'b0));
    fix_val = fix_neg ? (32'b0 - fix_src) : fix_src;

`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_DIV:  alt_val = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: alt_val = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  alt_val = (a - b) ^ 32'h8da68fa5;
      default:  alt_val = (a - b) ^ 32'h3138d0e1;  // ALU_REMU
    endcase
`endif
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state    <= S_IDLE;
      cnt      <= 5'd0;
      rem_q    <= 32'b0;
      quo_q    <= 32'b0;
      div_q    <= 32'b0;
      is_rem_q <= 1'b0;
      neg_q_q  <= 1'b0;
      neg_r_q  <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
`ifdef RISCV_FORMAL_ALTOPS
            quo_q    <= alt_val;
            rem_q    <= 32'b0;
            div_q    <= 32'b0;
            is_rem_q <= 1'b0;
            neg_q_q  <= 1'b0;
            neg_r_q  <= 1'b0;
            state    <= S_FIX;
`else
            quo_q    <= (is_signed && a[31]) ? (32'b0 - a) : a;
            div_q    <= (is_signed && b[31]) ? (32'b0 - b) : b;
            rem_q    <= 32'b0;
            is_rem_q <= is_rem;
            neg_q_q  <= is_signed && (a[31] ^ b[31]);
            neg_r_q  <= is_signed && a[31];
            state    <= S_RUN;
`endif
            cnt      <= 5'd0;
          end
        end
        S_RUN: begin
          if (diff[33]) begin
            rem_q <= trial[31:0];
            quo_q <= {quo_q[30:0], 1'b0};
          end else begin
            rem_q <= diff[31:0];
            quo_q <= {quo_q[30:0], 1'b1};
          end
          cnt <= cnt + 5'd1;
          if (cnt == 5'd31) state <= S_FIX;
        end
        S_FIX: begin
          quo_q <= fix_val;
          state <= S_DONE;
        end
        default: begin  // S_DONE
          if (accept) state <= S_IDLE;
        end
      endcase
      // The div left EX without being accepted (cannot happen in the
      // pipeline today; keeps the FSM self-recovering).
      if (!req) state <= S_IDLE;
    end
  end

  assign busy   = (state == S_RUN) || (state == S_FIX);
  assign done   = (state == S_DONE);
  assign result = quo_q;

endmodule
