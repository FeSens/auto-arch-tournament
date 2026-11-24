// rtl/alu.sv
//
// Integer results are combinational. The full multiply result advances with
// EX/MEM. DIV/REM capture operands, prepare 3D, then run six radix-4 rounds.
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
  input  logic [31:0] mul_rs1,
  input  logic [31:0] mul_rs2,
  input  logic        advance,
  output logic [31:0] product_low,
  output logic [31:0] product_high,
  input  logic        div_start,
  output logic        div_ready,
  output logic        div_valid,
  input  logic        div_consume,
  output logic [31:0] div_result
);

  typedef enum logic [1:0] {IDLE, PREP, RUN, DONE} div_state_t;
  div_state_t state_q;
  logic [2:0] round_q;

  assign div_ready = state_q == IDLE;
  assign div_valid = state_q == DONE;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      round_q <= '0;
    end else begin
      case (state_q)
        IDLE: if (div_start) begin
          state_q <= PREP;
          round_q <= '0;
        end
        PREP: state_q <= RUN;
        RUN: begin
          round_q <= round_q + 3'd1;
          if (round_q == 3'd5) state_q <= DONE;
        end
        DONE: if (div_consume) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_product;
  always_comb begin
    case (op)
      ALU_MUL:    alt_product = (mul_rs1 + mul_rs2) ^ 32'h5876063e;
      ALU_MULH:   alt_product = (mul_rs1 + mul_rs2) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_product = (mul_rs1 + mul_rs2) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_product = (mul_rs1 - mul_rs2) ^ 32'hecfbe137;
      default:    alt_product = 32'b0;
    endcase
  end
  always_ff @(posedge clock) begin
    if (advance) product_low <= alt_product;
  end
  assign product_high = product_low;

  logic [31:0] a_q, b_q;
  logic [4:0] op_q;

  always_ff @(posedge clock) begin
    if (div_start && div_ready) begin
      a_q <= a;
      b_q <= b;
      op_q <= op;
    end
  end

  always_comb begin
    case (op_q)
      ALU_DIV:  div_result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU: div_result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:  div_result = (a_q - b_q) ^ 32'h8da68fa5;
      default:  div_result = (a_q - b_q) ^ 32'h3138d0e1; // REMU
    endcase
  end
`else
  logic signed [32:0] mul_a, mul_b;
  assign mul_a = $signed({(op == ALU_MULH || op == ALU_MULHSU) && mul_rs1[31], mul_rs1});
  assign mul_b = $signed({(op == ALU_MULH) && mul_rs2[31], mul_rs2});
  always_ff @(posedge clock) begin
    if (advance) {product_high, product_low} <= mul_a * mul_b;
  end

  logic signed_op, want_rem;
  logic start, want_rem_q, negate_q, small_q, zero_quotient_q;
  logic [31:0] dividend_abs, divisor_q, magnitude;
  logic [31:0] small_quotient, wide_remainder;
  logic [7:0] small_remainder;
  logic [23:0] wide_quotient;

  assign start = div_start && div_ready;
  assign signed_op = op == ALU_DIV || op == ALU_REM;
  assign want_rem  = op == ALU_REM || op == ALU_REMU;
  assign dividend_abs = signed_op && a[31] ? -a : a;

  always_ff @(posedge clock) begin
    if (start) begin
      divisor_q  <= signed_op && b[31] ? -b : b;
      want_rem_q <= want_rem;
      negate_q   <= signed_op && (want_rem ? a[31] : (a[31] ^ b[31]));
    end else if (state_q == PREP) begin
      small_q <= divisor_q[31:8] == 0 && divisor_q[7:0] != 0;
      zero_quotient_q <= divisor_q == 0 && !want_rem_q;
    end
  end

  // For 0 < D < 256 every reduced remainder fits in a byte. For D >= 256
  // the top byte of the dividend is already reduced, with zero quotient.
  radix4_path #(.REM_BITS(8), .DIGITS(3)) u_small (
    .clock(clock), .start(start), .prep(state_q == PREP), .run(state_q == RUN),
    .divisor(divisor_q[7:0]), .initial_remainder(8'b0),
    .dividend_bits({4'b0, dividend_abs}), .remainder(small_remainder), .quotient(small_quotient)
  );
  radix4_path #(.REM_BITS(32), .DIGITS(2)) u_wide (
    .clock(clock), .start(start), .prep(state_q == PREP), .run(state_q == RUN),
    .divisor(divisor_q), .initial_remainder({24'b0, dividend_abs[31:24]}),
    .dividend_bits(dividend_abs[23:0]), .remainder(wide_remainder), .quotient(wide_quotient)
  );

  assign magnitude = small_q ? (want_rem_q ? {24'b0, small_remainder} : small_quotient)
                             : (want_rem_q ? wide_remainder : {8'b0, wide_quotient});
  // With D=0 the wide path subtracts zero at every digit, reconstructing
  // the entire dividend magnitude in its remainder register.
  assign div_result = zero_quotient_q ? 32'hffff_ffff : (negate_q ? -magnitude : magnitude);
`endif

  logic [4:0] shamt;
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

      default:  out = 32'b0;
    endcase
  end

endmodule
