// Capture raw operands at launch, seed two quotient bits in PREP, then
// consume five bits on each of six radix-8/radix-4 LOOP edges. DONE holds
// arithmetic and metadata; sign/exception correction feeds EX/MEM accept.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 2'd0, PREP = 2'd1,
                         LOOP = 2'd2, DONE = 2'd3;
  logic [1:0] state_q;
  logic [2:0] iteration_q;

  // Actual launch boundaries: their D inputs contain only raw forwarded
  // operands/op and hold/reset muxes. Preserve against Gowin absorption
  // and retiming into magnitude, seed or divisor-multiple arithmetic.
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [31:0] raw_a_q, raw_b_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [4:0] raw_op_q;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  assign result = alt_result_q;
`else
  logic [31:0] quotient_q, remainder_q;
  logic [31:0] quotient_next, remainder_next, quotient_radix8;
  logic [31:0] magnitude_a, magnitude_b;
  logic [34:0] divisor_multiple_q [1:7];
  logic [34:0] divisor_d, divisor_2d, divisor_4d, divisor_8d;
  logic signed_op, quotient_negative_q, remainder_negative_q;
  logic zero_q, overflow_q;
  logic [1:0] seed_quotient, seed_remainder;
  logic [34:0] numerator8, numerator4;
  logic [35:0] trial8 [1:7];
  logic [35:0] trial4 [1:3];
  logic [7:1] fit8;
  logic [3:1] fit4;
  logic [7:0] select8;
  // Keep the complete digit decode; residual selection bypasses bit zero.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [3:0] select4;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0] digit8;
  logic [1:0] digit4;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [34:0] residual8, residual4;
  /* verilator lint_on UNUSEDSIGNAL */

  assign signed_op = (raw_op_q == ALU_DIV || raw_op_q == ALU_REM);
  assign magnitude_a = (signed_op && raw_a_q[31]) ? -raw_a_q : raw_a_q;
  assign magnitude_b = (signed_op && raw_b_q[31]) ? -raw_b_q : raw_b_q;
  assign divisor_d  = {3'b0, magnitude_b};
  assign divisor_2d = {2'b0, magnitude_b, 1'b0};
  assign divisor_4d = {1'b0, magnitude_b, 2'b0};
  assign divisor_8d = {magnitude_b, 3'b0};

  // Constant two-bit division table, indexed by {divisor, numerator}.
  // Zero divisor seeds deterministically; architectural correction wins.
  always_comb begin
    seed_quotient = 2'b0;
    seed_remainder = magnitude_a[31:30];
    if (magnitude_b[31:2] == 30'b0) begin
      case ({magnitude_b[1:0], magnitude_a[31:30]})
        4'b0000: begin seed_quotient = 2'd0; seed_remainder = 2'd0; end
        4'b0001: begin seed_quotient = 2'd0; seed_remainder = 2'd1; end
        4'b0010: begin seed_quotient = 2'd0; seed_remainder = 2'd2; end
        4'b0011: begin seed_quotient = 2'd0; seed_remainder = 2'd3; end
        4'b0100: begin seed_quotient = 2'd0; seed_remainder = 2'd0; end
        4'b0101: begin seed_quotient = 2'd1; seed_remainder = 2'd0; end
        4'b0110: begin seed_quotient = 2'd2; seed_remainder = 2'd0; end
        4'b0111: begin seed_quotient = 2'd3; seed_remainder = 2'd0; end
        4'b1000: begin seed_quotient = 2'd0; seed_remainder = 2'd0; end
        4'b1001: begin seed_quotient = 2'd0; seed_remainder = 2'd1; end
        4'b1010: begin seed_quotient = 2'd1; seed_remainder = 2'd0; end
        4'b1011: begin seed_quotient = 2'd1; seed_remainder = 2'd1; end
        4'b1100: begin seed_quotient = 2'd0; seed_remainder = 2'd0; end
        4'b1101: begin seed_quotient = 2'd0; seed_remainder = 2'd1; end
        4'b1110: begin seed_quotient = 2'd0; seed_remainder = 2'd2; end
        4'b1111: begin seed_quotient = 2'd1; seed_remainder = 2'd0; end
        default: ;
      endcase
    end
  end

  assign numerator8 = {remainder_q, quotient_q[31:29]};
  for (genvar k = 1; k <= 7; k++) begin : g_radix8_trial
    assign trial8[k] = {1'b0, numerator8} - {1'b0, divisor_multiple_q[k]};
    assign fit8[k] = !trial8[k][35];
  end
  assign select8[0] = !fit8[1];
  for (genvar k = 1; k <= 6; k++) begin : g_radix8_select
    assign select8[k] = fit8[k] && !fit8[k+1];
  end
  assign select8[7] = fit8[7];
  assign digit8 = {(|(select8 & 8'b11110000)),
                   (|(select8 & 8'b11001100)),
                   (|(select8 & 8'b10101010))};
  // Ordered fits select the largest fitting multiple in three mux levels.
  // All trials/multiples stay full width, including high divisors.
  assign residual8 =
      fit8[4]
        ? (fit8[6] ? (fit8[7] ? trial8[7][34:0] : trial8[6][34:0])
                   : (fit8[5] ? trial8[5][34:0] : trial8[4][34:0]))
        : (fit8[2] ? (fit8[3] ? trial8[3][34:0] : trial8[2][34:0])
                   : (fit8[1] ? trial8[1][34:0] : numerator8));
  assign quotient_radix8 = {quotient_q[28:0], digit8};

  // Nonzero divisors restore a remainder < D, hence only its low 32 bits
  // feed the next digit. U is widened before all three parallel trials.
  assign numerator4 = {1'b0, residual8[31:0], quotient_radix8[31:30]};
  for (genvar k = 1; k <= 3; k++) begin : g_radix4_trial
    assign trial4[k] = {1'b0, numerator4} - {1'b0, divisor_multiple_q[k]};
    assign fit4[k] = !trial4[k][35];
  end
  assign select4[0] = !fit4[1];
  assign select4[1] = fit4[1] && !fit4[2];
  assign select4[2] = fit4[2] && !fit4[3];
  assign select4[3] = fit4[3];
  assign digit4 = {select4[2] | select4[3], select4[1] | select4[3]};
  assign residual4 =
      fit4[2]
        ? (fit4[3] ? trial4[3][34:0] : trial4[2][34:0])
        : (fit4[1] ? trial4[1][34:0] : numerator4);
  assign quotient_next = {quotient_radix8[29:0], digit4};
  assign remainder_next = residual4[31:0];

  // These sources remain frozen throughout DONE, including older memory
  // stalls. Correction is outside the registered LOOP recurrence.
  always_comb begin
    if (raw_op_q == ALU_REM || raw_op_q == ALU_REMU) begin
      if (zero_q) result = raw_a_q;
      else if (overflow_q) result = 32'b0;
      else result = remainder_negative_q ? -remainder_q : remainder_q;
    end else begin
      if (zero_q) result = 32'hffffffff;
      else if (overflow_q) result = 32'h80000000;
      else result = quotient_negative_q ? -quotient_q : quotient_q;
    end
  end
`endif

  assign busy = (state_q != IDLE);
  assign done = (state_q == DONE);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      iteration_q <= 3'b0;
      raw_op_q <= 5'b0;
      raw_a_q <= 32'b0;
      raw_b_q <= 32'b0;
`ifdef RISCV_FORMAL_ALTOPS
      alt_result_q <= 32'b0;
`else
      quotient_q <= 32'b0;
      remainder_q <= 32'b0;
      for (int k = 1; k <= 7; k++) divisor_multiple_q[k] <= 35'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      zero_q <= 1'b0;
      overflow_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (start) begin
          raw_op_q <= op;
          raw_a_q <= a;
          raw_b_q <= b;
          iteration_q <= 3'b0;
          state_q <= PREP;
        end
        PREP: begin
`ifdef RISCV_FORMAL_ALTOPS
          case (raw_op_q)
            ALU_DIV:  alt_result_q <= (raw_a_q - raw_b_q) ^ 32'h7f8529ec;
            ALU_DIVU: alt_result_q <= (raw_a_q - raw_b_q) ^ 32'h10e8fd70;
            ALU_REM:  alt_result_q <= (raw_a_q - raw_b_q) ^ 32'h8da68fa5;
            ALU_REMU: alt_result_q <= (raw_a_q - raw_b_q) ^ 32'h3138d0e1;
            default:  alt_result_q <= 32'b0;
          endcase
`else
          quotient_q <= {magnitude_a[29:0], seed_quotient};
          remainder_q <= {30'b0, seed_remainder};
          divisor_multiple_q[1] <= divisor_d;
          divisor_multiple_q[2] <= divisor_2d;
          divisor_multiple_q[3] <= divisor_d + divisor_2d;
          divisor_multiple_q[4] <= divisor_4d;
          divisor_multiple_q[5] <= divisor_d + divisor_4d;
          divisor_multiple_q[6] <= divisor_2d + divisor_4d;
          divisor_multiple_q[7] <= divisor_8d - divisor_d;
          quotient_negative_q <= signed_op && (raw_a_q[31] ^ raw_b_q[31]);
          remainder_negative_q <= signed_op && raw_a_q[31];
          zero_q <= (raw_b_q == 32'b0);
          overflow_q <= signed_op && (raw_a_q == 32'h80000000)
                                 && (raw_b_q == 32'hffffffff);
`endif
          state_q <= LOOP;
        end
        LOOP: begin
`ifndef RISCV_FORMAL_ALTOPS
          quotient_q <= quotient_next;
          remainder_q <= remainder_next;
`endif
          iteration_q <= iteration_q + 3'd1;
          if (iteration_q == 3'd5) state_q <= DONE;
        end
        DONE: if (accept) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
