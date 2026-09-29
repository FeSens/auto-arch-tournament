// rtl/mdu.sv
//
// Multi-cycle RV32M unit (MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU).
// Lives beside the 1-cycle ALU in EX so no `*`, `/` or `%` sits on the
// single-cycle EX combinational path.
//
// Handshake (driven by ex_stage):
//   start : ID/EX holds a valid M-op and the unit is idle with no result
//           pending. Latches op and the POST-FORWARD rs1/rs2 values.
//   done  : result (and the latched operands) valid; held until `hold`
//           is low, i.e. until EX/MEM actually captures the M-op.
//
// Multiply: one shared 33x33 signed product (operands sign- or
//           zero-extended per op), input regs -> product reg. start ->
//           +1 product -> +2 done (2 stall cycles).
// Divide:   radix-2 restoring divider on operand magnitudes, one quotient
//           bit per cycle (32 iterations) + sign fix-up. RV32M special
//           cases fall out of the magnitude algorithm:
//             x/0      -> q = all ones, r = x (quotient sign fix
//                         suppressed when divisor is 0)
//             INT_MIN/-1 -> |q| = 2^31 -> negated = INT_MIN, r = 0
//
// Under RISCV_FORMAL_ALTOPS the unit keeps the same handshake but
// produces the riscv-formal ALTOPS stand-ins with 1-cycle latency.
//
// Latency:        MUL* 2 extra cycles, DIV/REM* 35 extra cycles,
//                 ALTOPS 1 extra cycle.
// RVFI fields:    feeds rd_wdata (via EX/MEM), and rs1_rdata/rs2_rdata
//                 via the latched operands.
module mdu (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        hold,       // EX/MEM frozen: keep done/result
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        done,
  output logic [31:0] result,
  output logic [31:0] a_lat,      // latched operands (RVFI / write_data)
  output logic [31:0] b_lat
);

  logic        done_q;
  logic [31:0] a_q;
  logic [31:0] b_q;
  logic [31:0] result_q;

  assign done  = done_q;
  assign a_lat = a_q;
  assign b_lat = b_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt;
  always_comb begin
    case (op)
      ALU_MUL:    alt = (a + b) ^ 32'h5876063e;
      ALU_MULH:   alt = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    alt = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   alt = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    alt = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   alt = (a - b) ^ 32'h3138d0e1;
      default:    alt = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      done_q   <= 1'b0;
      a_q      <= 32'b0;
      b_q      <= 32'b0;
      result_q <= 32'b0;
    end else if (start) begin
      done_q   <= 1'b1;
      a_q      <= a;
      b_q      <= b;
      result_q <= alt;
    end else if (done_q && !hold) begin
      done_q   <= 1'b0;
    end
  end

  assign result = result_q;
`else
  typedef enum logic [2:0] {
    S_IDLE, S_MUL, S_DIV_INIT, S_DIV_ITER, S_DIV_FIN
  } state_t;

  state_t      state_q;
  logic [4:0]  op_q;

  // Multiplier: 33x33 signed, input + output registers (DSP-friendly).
  logic signed [32:0] ma_q;
  logic signed [32:0] mb_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod_full;   // [65:64] are sign copies, unused
  /* verilator lint_on UNUSEDSIGNAL */
  logic        [63:0] prod_q;
  logic               mul_hi_q;    // select high half
  logic               is_mul_q;    // result comes from prod_q

  // Divider working state.
  logic [31:0] quot_q;             // dividend shift-in / quotient shift-out
  logic [31:0] rem_q;
  logic [31:0] dvsr_q;
  logic [4:0]  cnt_q;
  logic        neg_q_q;
  logic        neg_r_q;

  logic        sa, sb;
  logic        div_signed;
  logic        a_neg, b_neg;
  logic [32:0] shifted;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;               // [32] is 0 whenever no borrow
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    // Signed-ness of multiplier operands per op.
    sa = (op == ALU_MULH) || (op == ALU_MULHSU);
    sb = (op == ALU_MULH);

    prod_full = ma_q * mb_q;

    div_signed = (op_q == ALU_DIV) || (op_q == ALU_REM);
    a_neg      = div_signed && a_q[31];
    b_neg      = div_signed && b_q[31];

    shifted = {rem_q, quot_q[31]};
    diff    = {1'b0, shifted} - {2'b0, dvsr_q};
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q  <= S_IDLE;
      done_q   <= 1'b0;
      op_q     <= 5'b0;
      a_q      <= 32'b0;
      b_q      <= 32'b0;
      ma_q     <= '0;
      mb_q     <= '0;
      prod_q   <= 64'b0;
      mul_hi_q <= 1'b0;
      is_mul_q <= 1'b0;
      quot_q   <= 32'b0;
      rem_q    <= 32'b0;
      dvsr_q   <= 32'b0;
      cnt_q    <= 5'b0;
      neg_q_q  <= 1'b0;
      neg_r_q  <= 1'b0;
      result_q <= 32'b0;
    end else begin
      if (done_q && !hold) done_q <= 1'b0;

      case (state_q)
        S_IDLE: begin
          if (start) begin
            op_q     <= op;
            a_q      <= a;
            b_q      <= b;
            ma_q     <= $signed({sa & a[31], a});
            mb_q     <= $signed({sb & b[31], b});
            mul_hi_q <= (op != ALU_MUL);
            is_mul_q <= (op == ALU_MUL) || (op == ALU_MULH) ||
                        (op == ALU_MULHU) || (op == ALU_MULHSU);
            state_q  <= ((op == ALU_MUL) || (op == ALU_MULH) ||
                         (op == ALU_MULHU) || (op == ALU_MULHSU))
                        ? S_MUL : S_DIV_INIT;
          end
        end

        S_MUL: begin
          prod_q  <= prod_full[63:0];
          done_q  <= 1'b1;
          state_q <= S_IDLE;
        end

        S_DIV_INIT: begin
          quot_q  <= a_neg ? (32'b0 - a_q) : a_q;
          dvsr_q  <= b_neg ? (32'b0 - b_q) : b_q;
          rem_q   <= 32'b0;
          cnt_q   <= 5'b0;
          neg_q_q <= (a_neg ^ b_neg) && (b_q != 32'b0);
          neg_r_q <= a_neg;
          state_q <= S_DIV_ITER;
        end

        S_DIV_ITER: begin
          if (!diff[33]) begin
            rem_q  <= diff[31:0];
            quot_q <= {quot_q[30:0], 1'b1};
          end else begin
            rem_q  <= shifted[31:0];
            quot_q <= {quot_q[30:0], 1'b0};
          end
          cnt_q <= cnt_q + 5'd1;
          if (cnt_q == 5'd31) state_q <= S_DIV_FIN;
        end

        S_DIV_FIN: begin
          if ((op_q == ALU_REM) || (op_q == ALU_REMU))
            result_q <= neg_r_q ? (32'b0 - rem_q)  : rem_q;
          else
            result_q <= neg_q_q ? (32'b0 - quot_q) : quot_q;
          done_q  <= 1'b1;
          state_q <= S_IDLE;
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign result = is_mul_q ? (mul_hi_q ? prod_q[63:32] : prod_q[31:0])
                           : result_q;
`endif

endmodule
