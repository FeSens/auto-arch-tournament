// rtl/div_unit.sv
//
// Iterative radix-2 restoring divider for DIV/DIVU/REM/REMU. Sits beside
// the ALU in EX; the pipeline front (PC + ID/EX) is held while it runs
// and EX/MEM captures bubbles (see ex_stage div_stall).
//
// FSM:
//   IDLE  : operands (post-forward rs1/rs2) and op are latched every IDLE
//           cycle; `start` (valid DIV* in ID/EX) moves to SETUP. Latching
//           matters: while the divide is held in EX the instructions ahead
//           of it drain, so the forwarding sources vanish.
//   SETUP : divide-by-zero finishes immediately (q = all ones, r = a).
//           Otherwise take |a|, |b| for signed ops and go to BUSY.
//           INT_MIN / -1 needs no special case: |a| = 2^31, |b| = 1 gives
//           q = 2^31 (no negate since both signs are set), r = 0.
//   BUSY  : 32 shift/subtract/select steps on {rem, quo}.
//   FIX   : negate quotient if sign(a)^sign(b), remainder if sign(a).
//   DONE  : hold result until EX/MEM captures it (`consume` =
//           !stall_ex_mem), then return to IDLE.
//
// result is 0 in every state except DONE (cleared on consume), so the EX
// stage can OR it into the ALU result (the ALU emits 0 for DIV* ops).
//
// Under RISCV_FORMAL_ALTOPS SETUP goes straight to DONE with the
// riscv-formal ALTOPS substitutes, so the stall/forward path is still
// covered inside the depth-20 BMC.
//
// op encoding = funct3[1:0]: 00 DIV, 01 DIVU, 10 REM, 11 REMU.
//
// Latency:        start + SETUP + 32 BUSY + FIX -> DONE (35 cycles before
//                 the result is available in DONE); div-by-zero: 2 cycles.
// RVFI fields:    rd_wdata of DIV*; a_q/b_q feed rs1_rdata/rs2_rdata.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,     // valid DIV* in ID/EX
  input  logic [1:0]  op,        // funct3[1:0]
  input  logic [31:0] a,         // post-forward rs1
  input  logic [31:0] b,         // post-forward rs2
  input  logic        consume,   // EX/MEM advances this cycle
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_q,       // latched operands (for RVFI)
  output logic [31:0] b_q
);

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_SETUP = 3'd1;
  localparam logic [2:0] S_BUSY  = 3'd2;
  localparam logic [2:0] S_FIX   = 3'd3;
  localparam logic [2:0] S_DONE  = 3'd4;

  logic [2:0]  state_q;
  logic [1:0]  op_q;
  logic [31:0] result_q;
  logic [31:0] rem_q;
  logic [31:0] quo_q;
  logic [31:0] dvsr_q;
  logic [4:0]  cnt_q;
  logic        neg_quo_q;
  logic        neg_rem_q;

  // SETUP: signs and magnitudes of the latched operands.
  logic        is_signed;
  logic        a_neg;
  logic        b_neg;
  logic [31:0] a_abs;
  logic [31:0] b_abs;

  // BUSY: one restoring step. rem < dvsr always holds, so rem_sh[32]
  // and diff[32] carry no information beyond the borrow in diff[33].
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] rem_sh;
  logic [33:0] diff;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    is_signed = !op_q[0];
    a_neg     = is_signed && a_q[31];
    b_neg     = is_signed && b_q[31];
    a_abs     = a_neg ? (32'b0 - a_q) : a_q;
    b_abs     = b_neg ? (32'b0 - b_q) : b_q;

    rem_sh    = {rem_q, quo_q[31]};
    diff      = {1'b0, rem_sh} - {2'b0, dvsr_q};
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q  <= S_IDLE;
      result_q <= 32'b0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (start) state_q <= S_SETUP;
        end

        S_SETUP: begin
`ifdef RISCV_FORMAL_ALTOPS
          case (op_q)
            2'd0:    result_q <= (a_q - b_q) ^ 32'h7f8529ec;  // DIV
            2'd1:    result_q <= (a_q - b_q) ^ 32'h10e8fd70;  // DIVU
            2'd2:    result_q <= (a_q - b_q) ^ 32'h8da68fa5;  // REM
            default: result_q <= (a_q - b_q) ^ 32'h3138d0e1;  // REMU
          endcase
          state_q <= S_DONE;
`else
          if (b_q == 32'b0) begin
            result_q <= op_q[1] ? a_q : 32'hFFFFFFFF;
            state_q  <= S_DONE;
          end else begin
            state_q  <= S_BUSY;
          end
`endif
        end

        S_BUSY: begin
          if (cnt_q == 5'd31) state_q <= S_FIX;
        end

        S_FIX: begin
          if (op_q[1]) result_q <= neg_rem_q ? (32'b0 - rem_q) : rem_q;
          else         result_q <= neg_quo_q ? (32'b0 - quo_q) : quo_q;
          state_q <= S_DONE;
        end

        S_DONE: begin
          if (consume) begin
            result_q <= 32'b0;
            state_q  <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  // Datapath registers (no reset needed; qualified by state_q).
  always_ff @(posedge clock) begin
    if (state_q == S_IDLE) begin
      a_q  <= a;
      b_q  <= b;
      op_q <= op;
    end
    if (state_q == S_SETUP) begin
      rem_q     <= 32'b0;
      quo_q     <= a_abs;
      dvsr_q    <= b_abs;
      cnt_q     <= 5'd0;
      neg_quo_q <= a_neg ^ b_neg;
      neg_rem_q <= a_neg;
    end
    if (state_q == S_BUSY) begin
      if (!diff[33]) begin
        rem_q <= diff[31:0];
        quo_q <= {quo_q[30:0], 1'b1};
      end else begin
        rem_q <= rem_sh[31:0];
        quo_q <= {quo_q[30:0], 1'b0};
      end
      cnt_q <= cnt_q + 5'd1;
    end
  end

  assign done   = (state_q == S_DONE);
  assign result = result_q;

endmodule
