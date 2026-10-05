// rtl/alu.sv
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
//
// RV32IM ALU. Base operations and multiplication are combinational;
// DIV/REM share a registered radix-2 restoring divider.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Divider requests capture op/a/b once. busy includes a completed request;
// result_valid and div_result remain stable until consume. Ordinary divides
// complete 34 clocks after the start edge (preparation, 32 bits, correction).
// Synchronous cancel discards any request or held result before all FSM work.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu #(
  parameter bit FULL_MUL_ENABLED = 1'b1
) (
  input  logic        clock,
  input  logic        reset,
  input  logic        cancel,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic        busy,
  output logic        result_valid,
  output logic [31:0] div_result
);

  logic        [4:0]  shamt;

  localparam logic [2:0] DIV_IDLE = 3'd0, DIV_PREP = 3'd1, DIV_DONE = 3'd4;
`ifndef RISCV_FORMAL_ALTOPS
  localparam logic [2:0] DIV_RUN = 3'd2, DIV_FINISH = 3'd3;
`endif
  logic [2:0] div_state_q;
  logic [4:0] div_op_q;
  logic [31:0] dividend_q, operand_b_q;

  assign busy = div_state_q != DIV_IDLE;
  assign result_valid = div_state_q == DIV_DONE;

`ifndef RISCV_FORMAL_ALTOPS
  logic [31:0] divisor_q, quotient_q;
  logic [32:0] remainder_q;
  logic [4:0] bit_q;
  logic quotient_negative_q, remainder_negative_q;
  logic signed_op, remainder_op;
  logic [32:0] shifted_remainder, trial_remainder;

  assign signed_op = div_op_q == ALU_DIV || div_op_q == ALU_REM;
  assign remainder_op = div_op_q == ALU_REM || div_op_q == ALU_REMU;
  // At iteration k the remainder contains at most k dividend bits, so
  // the shifted value fits in 32 bits. Bit 32 of the subtraction is borrow.
  assign shifted_remainder = (remainder_q << 1) | {32'b0, quotient_q[31]};
  assign trial_remainder = shifted_remainder - {1'b0, divisor_q};
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      div_state_q <= DIV_IDLE;
      div_op_q <= ALU_ADD;
      dividend_q <= 32'b0;
      operand_b_q <= 32'b0;
      div_result <= 32'b0;
`ifndef RISCV_FORMAL_ALTOPS
      divisor_q <= 32'b0;
      quotient_q <= 32'b0;
      remainder_q <= 33'b0;
      bit_q <= 5'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
`endif
    end else if (cancel) begin
      // Older recovery discards the transaction, including held completion.
      // Arithmetic storage may remain, but only a fresh start can validate it.
      div_state_q <= DIV_IDLE;
    end else begin
      case (div_state_q)
        DIV_IDLE: begin
          if (start && (op == ALU_DIV || op == ALU_DIVU ||
                        op == ALU_REM || op == ALU_REMU)) begin
            dividend_q <= a;
            operand_b_q <= b;
            div_op_q <= op;
            div_state_q <= DIV_PREP;
          end
        end
        DIV_PREP: begin
`ifdef RISCV_FORMAL_ALTOPS
          // Exact riscv-formal stand-ins, with the same held transaction
          // interface and a short completion for the unchanged BMC depth.
          case (div_op_q)
            ALU_DIV:  div_result <= (dividend_q - operand_b_q) ^ 32'h7f8529ec;
            ALU_DIVU: div_result <= (dividend_q - operand_b_q) ^ 32'h10e8fd70;
            ALU_REM:  div_result <= (dividend_q - operand_b_q) ^ 32'h8da68fa5;
            ALU_REMU: div_result <= (dividend_q - operand_b_q) ^ 32'h3138d0e1;
            default:  div_result <= 32'b0;
          endcase
          div_state_q <= DIV_DONE;
`else
          // Magnitude preparation is separate from the iterative subtractor.
          quotient_q <= (signed_op && dividend_q[31]) ? -dividend_q : dividend_q;
          divisor_q <= (signed_op && operand_b_q[31]) ? -operand_b_q : operand_b_q;
          remainder_q <= 33'b0;
          bit_q <= 5'b0;
          quotient_negative_q <= signed_op && (dividend_q[31] ^ operand_b_q[31]);
          remainder_negative_q <= signed_op && dividend_q[31];
          if (operand_b_q == 32'b0) begin
            div_result <= remainder_op ? dividend_q : 32'hffffffff;
            div_state_q <= DIV_DONE;
          end else if (signed_op && dividend_q == 32'h80000000 &&
                       operand_b_q == 32'hffffffff) begin
            div_result <= remainder_op ? 32'b0 : 32'h80000000;
            div_state_q <= DIV_DONE;
          end else begin
            div_state_q <= DIV_RUN;
          end
`endif
        end
`ifndef RISCV_FORMAL_ALTOPS
        DIV_RUN: begin
          if (trial_remainder[32]) begin
            remainder_q <= shifted_remainder;
            quotient_q <= {quotient_q[30:0], 1'b0};
          end else begin
            remainder_q <= trial_remainder;
            quotient_q <= {quotient_q[30:0], 1'b1};
          end
          bit_q <= bit_q + 5'd1;
          if (bit_q == 5'd31) div_state_q <= DIV_FINISH;
        end
        DIV_FINISH: begin
          // Sign correction uses the final registered magnitudes only.
          if (remainder_op)
            div_result <= remainder_negative_q ? -remainder_q[31:0] : remainder_q[31:0];
          else
            div_result <= quotient_negative_q ? -quotient_q : quotient_q;
          div_state_q <= DIV_DONE;
        end
`endif
        DIV_DONE: if (consume) div_state_q <= DIV_IDLE;
        default: div_state_q <= DIV_IDLE;
      endcase
    end
  end

`ifndef RISCV_FORMAL_ALTOPS
  // 64-bit products, computed once and selected per op. EX disables
  // this cone at elaboration; its speculative multiplier is separate.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */

  generate
    if (FULL_MUL_ENABLED) begin : g_full_mul
      assign mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
      assign mul_uu = {32'b0, a} * {32'b0, b};
      assign mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
    end else begin : g_no_full_mul
      assign mul_ss = 64'b0;
      assign mul_uu = 64'b0;
      assign mul_su = 64'b0;
    end
  endgenerate
`endif

  always_comb begin
    shamt = b[4:0];

    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = a << shamt;
      ALU_SRL:    out = a >> shamt;
      ALU_SRA:    out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    out = b;

      // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
      // are substituted for tractable algebraic stand-ins so bitwuzla
      // can solve the BMC inside the 20-step depth budget. The same
      // substitution must appear in the riscv-formal spec (insn_*.v).
      // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
      // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
`endif
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
