// rtl/divider.sv
//
// Sequential radix-2 restoring divider for DIV / DIVU / REM / REMU.
//
// The combinational `/` and `%` array divider was the single longest
// path in the core (a chain of 32 compare/subtract stages). This module
// replaces it with a 1-bit-per-cycle iteration so the timed critical
// path is bounded by one 33-bit subtract.
//
// Protocol (driven by ex_stage):
//   - `start` is high while a divide instruction sits in EX and the
//     divider is IDLE. On that cycle the raw (forwarded) rs1/rs2 are
//     captured into op_a / op_b. After that the divider never looks at
//     a / b again: by the time the divide finishes the EX/MEM and
//     MEM/WB forwarding sources have moved on and ID/EX.rs?_val is
//     stale, so the latched copy is the only reliable operand source.
//   - States: IDLE -> PREP -> RUN (32 cycles) -> FIN -> DONE.
//       PREP : take absolute values (negate when signed and MSB set),
//              record result-sign flags and the divide-by-zero flag.
//       RUN  : 32 restoring iterations, one quotient bit per cycle.
//       FIN  : pick quotient or remainder and apply one shared
//              conditional negate into the registered `result`.
//       DONE : `done` = 1, `result` valid. Holds until `advance`
//              (the divide leaves EX), then returns to IDLE.
//   - The FSM does not depend on the dmem stall: it only needs to know
//     when the instruction has actually left EX (`advance`).
//
// RV32M corner cases fall out of the algorithm:
//   - x / 0: dvs = 0, so every iteration subtracts 0 and shifts in a 1:
//     quotient = 0xFFFFFFFF; remainder = |dividend| and neg_r = sign
//     of the dividend restores the original dividend. neg_q is
//     suppressed for b == 0 so the quotient is not negated.
//   - INT_MIN / -1: |INT_MIN| / 1 = 0x80000000, quotient sign
//     (1 ^ 1) = positive -> 0x80000000; remainder 0.
//
// Latency:        ~36 cycles from the first EX cycle to DONE.
// RVFI fields:    op_a / op_b feed rs1_rdata / rs2_rdata of the divide
//                 (RVFI-only; pruned from the timed netlist).
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,       // divide in EX (valid && div op)
  input  logic [31:0] a,           // forwarded rs1 (sampled in IDLE)
  input  logic [31:0] b,           // forwarded rs2 (sampled in IDLE)
  input  logic        is_signed,   // DIV / REM
  input  logic        want_rem,    // REM / REMU
  input  logic        advance,     // divide result consumed -> back to IDLE
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] op_a,        // latched operands (RVFI)
  output logic [31:0] op_b
);

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_PREP = 3'd1;
  localparam logic [2:0] S_RUN  = 3'd2;
  localparam logic [2:0] S_FIN  = 3'd3;
  localparam logic [2:0] S_DONE = 3'd4;

  logic [2:0]  state;
  logic [4:0]  count;
  logic        sgn_q;       // latched is_signed
  logic        rem_q;       // latched want_rem
  logic [31:0] quo;         // dividend (|a|) shifting out / quotient shifting in
  logic [31:0] rem;         // partial remainder
  logic [31:0] dvs;         // |b|
  logic        neg_q;       // negate quotient
  logic        neg_r;       // negate remainder
  logic [31:0] res_q;

  // One restoring iteration. 33-bit compare so rem[31] is not lost.
  logic [32:0] shifted;
  logic [32:0] diff;
  logic        ge;
  always_comb begin
    shifted = {rem, quo[31]};
    diff    = shifted - {1'b0, dvs};
    ge      = !diff[32];   // no borrow -> shifted >= dvs
  end

  // Shared conditional negate for FIN.
  logic [31:0] fin_sel;
  logic        fin_neg;
  logic [31:0] fin_val;
  always_comb begin
    fin_sel = rem_q ? rem   : quo;
    fin_neg = rem_q ? neg_r : neg_q;
    fin_val = fin_neg ? (32'b0 - fin_sel) : fin_sel;
  end

  // Absolute values for PREP.
  logic        a_neg;
  logic        b_neg;
  always_comb begin
    a_neg = sgn_q && op_a[31];
    b_neg = sgn_q && op_b[31];
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            op_a  <= a;
            op_b  <= b;
            sgn_q <= is_signed;
            rem_q <= want_rem;
            state <= S_PREP;
          end
        end

        S_PREP: begin
          quo   <= a_neg ? (32'b0 - op_a) : op_a;
          dvs   <= b_neg ? (32'b0 - op_b) : op_b;
          rem   <= 32'b0;
          neg_q <= (a_neg != b_neg) && (op_b != 32'b0);
          neg_r <= a_neg;
          count <= 5'd0;
          state <= S_RUN;
        end

        S_RUN: begin
          if (ge) begin
            rem <= diff[31:0];
            quo <= {quo[30:0], 1'b1};
          end else begin
            rem <= shifted[31:0];
            quo <= {quo[30:0], 1'b0};
          end
          count <= count + 5'd1;
          if (count == 5'd31) state <= S_FIN;
        end

        S_FIN: begin
          res_q <= fin_val;
          state <= S_DONE;
        end

        S_DONE: begin
          if (advance) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // S_DONE (3'd4) is the only state with bit 2 set (5..7 are unreachable), so
  // `done` is one flop output: ex_busy is a single LUT of flops.
  assign done   = state[2];
  assign result = res_q;

endmodule
