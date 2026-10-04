// rtl/divider.sv
//
// Iterative RV32M divider: radix-2 restoring division, one quotient bit
// per cycle. Replaces the single-cycle `/` and `%` V0 had in alu.sv.
//
//   cycle 0       start: latch |a|, |b| and the result signs
//   cycles 1..32  one shift-and-subtract step each
//   cycle 33      done: sign-corrected quotient or remainder on `result`,
//                 held until `ack`
//
// RV32M special cases come out of the datapath unchanged except divide by
// zero, which is caught at start:
//   DIV/DIVU by 0   -> all ones       REM/REMU by 0 -> dividend
//   DIV INT_MIN/-1  -> INT_MIN        REM INT_MIN/-1 -> 0
//
// Under RISCV_FORMAL_ALTOPS the result is the riscv-formal stand-in formula
// of the latched operands and `done` follows start by one cycle, so formal
// still exercises the EX stall and bubble path; a 34-cycle stall would not
// fit the liveness check's 10-cycle window.
//
// Latency:        34 cycles in EX (2 under ALTOPS).
// RVFI fields:    feeds rd_wdata for DIV/DIVU/REM/REMU via ex_stage.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req,      // a DIV/DIVU/REM/REMU sits in EX
  input  logic        ack,      // EX/MEM captures the result this cycle
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        done,
  output logic [31:0] result
);

  typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } state_t;
  state_t state;

  logic [4:0]  cnt;
  logic [31:0] quo_q;    // dividend shifting out, quotient shifting in
  logic [31:0] rem_q;    // partial remainder
  logic [31:0] div_q;    // |divisor|
  logic        neg_q;    // quotient negative
  logic        neg_r;    // remainder negative (sign of the dividend)
  logic        is_rem_q;
  logic        by_zero_q;
  logic [31:0] a_q;      // dividend, for REM by zero

  logic        is_signed;
  logic        start;
  logic [32:0] shifted;
  logic [32:0] diff;

  always_comb begin
    start     = req && (state == S_IDLE);
    is_signed = (op == ALU_DIV) || (op == ALU_REM);
    shifted   = {rem_q, quo_q[31]};
    diff      = shifted - {1'b0, div_q};
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_val;
  always_comb begin
    case (op)
      ALU_DIV:  alt_val = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: alt_val = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  alt_val = (a - b) ^ 32'h8da68fa5;
      default:  alt_val = (a - b) ^ 32'h3138d0e1;  // ALU_REMU
    endcase
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state     <= S_IDLE;
      cnt       <= 5'd0;
      quo_q     <= 32'b0;
      rem_q     <= 32'b0;
      div_q     <= 32'b0;
      neg_q     <= 1'b0;
      neg_r     <= 1'b0;
      is_rem_q  <= 1'b0;
      by_zero_q <= 1'b0;
      a_q       <= 32'b0;
    end else begin
      case (state)
        S_IDLE: if (start) begin
`ifdef RISCV_FORMAL_ALTOPS
          quo_q     <= alt_val;
          neg_q     <= 1'b0;
          neg_r     <= 1'b0;
          is_rem_q  <= 1'b0;
          by_zero_q <= 1'b0;
          state     <= S_DONE;
`else
          quo_q     <= (is_signed && a[31]) ? (32'b0 - a) : a;
          div_q     <= (is_signed && b[31]) ? (32'b0 - b) : b;
          neg_q     <= is_signed && (a[31] ^ b[31]);
          neg_r     <= is_signed && a[31];
          is_rem_q  <= (op == ALU_REM) || (op == ALU_REMU);
          by_zero_q <= (b == 32'b0);
          state     <= S_RUN;
`endif
          rem_q     <= 32'b0;
          a_q       <= a;
          cnt       <= 5'd0;
        end
        S_RUN: begin
          if (diff[32]) begin
            rem_q <= shifted[31:0];
            quo_q <= {quo_q[30:0], 1'b0};
          end else begin
            rem_q <= diff[31:0];
            quo_q <= {quo_q[30:0], 1'b1};
          end
          cnt <= cnt + 5'd1;
          if (cnt == 5'd31) state <= S_DONE;
        end
        default: if (ack) state <= S_IDLE;  // S_DONE
      endcase
      // The instruction left EX without taking the result (cannot happen
      // in this pipeline); return to idle rather than hang.
      if (!req) state <= S_IDLE;
    end
  end

  always_comb begin
    done = (state == S_DONE);
`ifdef RISCV_FORMAL_ALTOPS
    result = quo_q;
`else
    if (by_zero_q)
      result = is_rem_q ? a_q : 32'hFFFFFFFF;
    else if (is_rem_q)
      result = neg_r ? (32'b0 - rem_q) : rem_q;
    else
      result = neg_q ? (32'b0 - quo_q) : quo_q;
`endif
  end

endmodule
