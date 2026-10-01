// rtl/alu.sv
//
// RV32IM fast ALU with blocking registered multiplication and division.
// Multiplication captures forwarded operands, registers an unsigned product,
// then completes MUL. High halves get a separate registered correction step.
// A division request captures op/a/b on valid && ready. Real arithmetic
// takes 32 subtract/select cycles and one registered sign-correction cycle.
// Completion stays valid, with stable data, until result_ready accepts it.
// ALTOPS registers the established abstraction through the same handshake.
// Latency:        ordinary integer operations remain combinational.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  input  logic        mul_req_valid,
  output logic        mul_req_ready,
  output logic        mul_result_valid,
  input  logic        mul_result_ready,
  output logic [31:0] mul_result,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_result_valid,
  input  logic        div_result_ready,
  output logic [31:0] div_result
);

  logic [3:0] low_sel, mid_sel;
  logic [31:0] left_low, left_mid, left_word;
  logic [31:0] right_low, right_mid, right_word;
  logic fill;

  // Group the five-bit shift amount into 0/1/2/3, 0/4/8/12 and 0/16.
  // Each four-way step masks fixed slices with mutually exclusive selects.
  assign low_sel = 4'b0001 << b[1:0];
  assign mid_sel = 4'b0001 << b[3:2];
  assign left_low = ({32{low_sel[0]}} & a) |
                    ({32{low_sel[1]}} & {a[30:0], 1'b0}) |
                    ({32{low_sel[2]}} & {a[29:0], 2'b0}) |
                    ({32{low_sel[3]}} & {a[28:0], 3'b0});
  assign left_mid = ({32{mid_sel[0]}} & left_low) |
                    ({32{mid_sel[1]}} & {left_low[27:0], 4'b0}) |
                    ({32{mid_sel[2]}} & {left_low[23:0], 8'b0}) |
                    ({32{mid_sel[3]}} & {left_low[19:0], 12'b0});
  assign left_word = b[4] ? {left_mid[15:0], 16'b0} : left_mid;

  // SRL and SRA share data routing. Every step uses the original sign
  // fill so arithmetic extension also survives the grouped boundaries.
  assign fill = (op == ALU_SRA) && a[31];
  assign right_low = ({32{low_sel[0]}} & a) |
                     ({32{low_sel[1]}} & {fill, a[31:1]}) |
                     ({32{low_sel[2]}} & {{2{fill}}, a[31:2]}) |
                     ({32{low_sel[3]}} & {{3{fill}}, a[31:3]});
  assign right_mid = ({32{mid_sel[0]}} & right_low) |
                     ({32{mid_sel[1]}} & {{4{fill}}, right_low[31:4]}) |
                     ({32{mid_sel[2]}} & {{8{fill}}, right_low[31:8]}) |
                     ({32{mid_sel[3]}} & {{12{fill}}, right_low[31:12]});
  assign right_word = b[4] ? {{16{fill}}, right_mid[31:16]} : right_mid;

  localparam logic [1:0] MUL_IDLE = 2'd0;
  localparam logic [1:0] MUL_CALC = 2'd1;
  localparam logic [1:0] MUL_HIGH = 2'd2;
  localparam logic [1:0] MUL_DONE = 2'd3;
  logic [1:0] mul_state_q;
  logic [4:0] mul_op_q;
  logic [31:0] mul_a_q, mul_b_q, mul_high_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] mul_product_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic mul_op;

  assign mul_op = op == ALU_MUL || op == ALU_MULH ||
                  op == ALU_MULHU || op == ALU_MULHSU;
  assign mul_req_ready = mul_state_q == MUL_IDLE && div_state_q == DIV_IDLE && !reset;
  assign mul_result_valid = mul_state_q == MUL_DONE && !reset;
  assign mul_result = mul_op_q == ALU_MUL ? mul_product_q[31:0] : mul_high_q;

  always_ff @(posedge clock) begin
    if (reset) mul_state_q <= MUL_IDLE;
    else begin
      case (mul_state_q)
        MUL_IDLE: if (mul_req_valid && mul_req_ready && mul_op)
                    mul_state_q <= MUL_CALC;
        MUL_CALC: mul_state_q <= mul_op_q == ALU_MUL ? MUL_DONE : MUL_HIGH;
        MUL_HIGH: mul_state_q <= MUL_DONE;
        MUL_DONE: if (mul_result_ready) mul_state_q <= MUL_IDLE;
        default: mul_state_q <= MUL_IDLE;
      endcase
    end
  end

  // The operand and product registers are real boundaries: neither the
  // DSP arithmetic nor high-word correction reads the live forwarding mux.
  // Payload registers need no reset; reset cancels validity and ownership.
  always_ff @(posedge clock) begin
    if (!reset) begin
      if (mul_req_valid && mul_req_ready && mul_op) begin
        mul_a_q <= a;
        mul_b_q <= b;
        mul_op_q <= op;
      end
      if (mul_state_q == MUL_CALC) begin
`ifdef RISCV_FORMAL_ALTOPS
        case (mul_op_q)
          ALU_MUL:    mul_product_q <= {32'b0, (mul_a_q + mul_b_q) ^ 32'h5876063e};
          ALU_MULH:   mul_product_q <= {32'b0, (mul_a_q + mul_b_q) ^ 32'hf6583fb7};
          ALU_MULHU:  mul_product_q <= {32'b0, (mul_a_q + mul_b_q) ^ 32'h949ce5e8};
          ALU_MULHSU: mul_product_q <= {32'b0, (mul_a_q - mul_b_q) ^ 32'hecfbe137};
          default:    mul_product_q <= 64'b0;
        endcase
`else
        // Explicit unsigned 32-by-32 product with a full 64-bit result.
        mul_product_q <= {32'b0, mul_a_q} * {32'b0, mul_b_q};
`endif
      end
      if (mul_state_q == MUL_HIGH) begin
`ifdef RISCV_FORMAL_ALTOPS
        mul_high_q <= mul_product_q[31:0];
`else
        case (mul_op_q)
          ALU_MULHU:  mul_high_q <= mul_product_q[63:32];
          ALU_MULHSU: mul_high_q <= mul_product_q[63:32]
                                 - (mul_a_q[31] ? mul_b_q : 32'b0);
          ALU_MULH:   mul_high_q <= mul_product_q[63:32]
                                 - (mul_a_q[31] ? mul_b_q : 32'b0)
                                 - (mul_b_q[31] ? mul_a_q : 32'b0);
          default:    mul_high_q <= 32'b0;
        endcase
`endif
      end
    end
  end

  localparam logic [1:0] DIV_IDLE = 2'd0;
`ifndef RISCV_FORMAL_ALTOPS
  localparam logic [1:0] DIV_RUN  = 2'd1;
  localparam logic [1:0] DIV_SIGN = 2'd2;
`endif
  localparam logic [1:0] DIV_DONE = 2'd3;
  logic [1:0] div_state_q;
  logic [31:0] div_result_q;
  logic div_op;

  assign div_op = op == ALU_DIV || op == ALU_DIVU ||
                  op == ALU_REM || op == ALU_REMU;
  assign div_req_ready = div_state_q == DIV_IDLE && mul_state_q == MUL_IDLE && !reset;
  assign div_result_valid = div_state_q == DIV_DONE && !reset;
  assign div_result = div_result_q;

`ifndef RISCV_FORMAL_ALTOPS
  logic [31:0] quotient_q, remainder_q, divisor_q;
  logic [4:0] iterations_q;
  logic quotient_negative_q, remainder_negative_q, want_remainder_q;
  logic signed_div;
  logic [32:0] shifted_remainder, trial_difference;
  logic [31:0] next_quotient, next_remainder;

  assign signed_div = op == ALU_DIV || op == ALU_REM;
  // The previous remainder is less than the divisor. A nonnegative
  // difference fits in 32 bits; bit 32 therefore reports the borrow.
  assign shifted_remainder = {remainder_q, quotient_q[31]};
  assign trial_difference = shifted_remainder - {1'b0, divisor_q};
  assign next_remainder = trial_difference[32]
                        ? shifted_remainder[31:0] : trial_difference[31:0];
  assign next_quotient = {quotient_q[30:0], !trial_difference[32]};
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      div_state_q <= DIV_IDLE;
      div_result_q <= 32'b0;
`ifndef RISCV_FORMAL_ALTOPS
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      divisor_q <= 32'b0;
      iterations_q <= 5'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      want_remainder_q <= 1'b0;
`endif
    end else begin
      case (div_state_q)
        DIV_IDLE: begin
          if (div_req_valid && div_req_ready && div_op) begin
`ifdef RISCV_FORMAL_ALTOPS
            case (op)
              ALU_DIV:  div_result_q <= (a - b) ^ 32'h7f8529ec;
              ALU_DIVU: div_result_q <= (a - b) ^ 32'h10e8fd70;
              ALU_REM:  div_result_q <= (a - b) ^ 32'h8da68fa5;
              ALU_REMU: div_result_q <= (a - b) ^ 32'h3138d0e1;
              default:  div_result_q <= 32'b0;
            endcase
            div_state_q <= DIV_DONE;
`else
            quotient_q <= signed_div && a[31] ? (32'b0 - a) : a;
            divisor_q <= signed_div && b[31] ? (32'b0 - b) : b;
            remainder_q <= 32'b0;
            iterations_q <= 5'd31;
            // Zero divisor generates an all-ones quotient naturally;
            // suppress its sign correction. Remainder recovers dividend.
            quotient_negative_q <= signed_div && (a[31] ^ b[31]) && b != 32'b0;
            remainder_negative_q <= signed_div && a[31];
            want_remainder_q <= op == ALU_REM || op == ALU_REMU;
            div_state_q <= DIV_RUN;
`endif
          end
        end
`ifndef RISCV_FORMAL_ALTOPS
        DIV_RUN: begin
          quotient_q <= next_quotient;
          remainder_q <= next_remainder;
          if (iterations_q == 5'b0) div_state_q <= DIV_SIGN;
          else iterations_q <= iterations_q - 5'd1;
        end
        DIV_SIGN: begin
          if (want_remainder_q)
            div_result_q <= remainder_negative_q ? (32'b0 - remainder_q) : remainder_q;
          else
            div_result_q <= quotient_negative_q ? (32'b0 - quotient_q) : quotient_q;
          div_state_q <= DIV_DONE;
        end
`endif
        DIV_DONE: if (div_result_ready) div_state_q <= DIV_IDLE;
        default: div_state_q <= DIV_IDLE;
      endcase
    end
  end

  always_comb begin
    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = left_word;
      ALU_SRL:    out = right_word;
      ALU_SRA:    out = right_word;
      ALU_LUI:    out = b;

      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU: out = mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result_q;
      default:  out = 32'b0;
    endcase
  end

endmodule
