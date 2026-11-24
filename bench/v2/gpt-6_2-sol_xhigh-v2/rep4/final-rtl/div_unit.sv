// Launch captures the operands. Preparation and seven reciprocal pipeline
// updates follow. Completion holds until the EX/MEM transfer consumes it.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        ready,
  output logic        done,
  output logic [31:0] result
);

  logic       active_q;
  logic       prepare_q;
  logic [2:0] cycles_left_q;
  logic       launch;
  logic       iterate;
  logic [4:0] op_q;
  logic [31:0] a_q, b_q;

  assign ready   = !active_q;
  assign done    = active_q && !prepare_q && (cycles_left_q == 3'd0);
  assign launch  = start && ready && !reset;
  assign iterate = active_q && !prepare_q && !done;

  always_ff @(posedge clock) begin
    if (launch) begin
      op_q <= op;
      a_q  <= a;
      b_q  <= b;
    end

    prepare_q <= launch;
    if (reset) begin
      active_q      <= 1'b0;
      cycles_left_q <= 3'd0;
    end else if (launch) begin
      active_q      <= 1'b1;
    end else if (prepare_q) begin
      cycles_left_q <= 3'd7;
    end else if (iterate) begin
      cycles_left_q <= cycles_left_q - 3'd1;
    end else if (done && consume) begin
      active_q      <= 1'b0;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Keep the native divider's handshake and update schedule.
  logic [31:0] alt_mask;
  logic [31:0] alt_result_q;

  always_comb begin
    case (op_q)
      ALU_DIV:  alt_mask = 32'h7f8529ec;
      ALU_DIVU: alt_mask = 32'h10e8fd70;
      ALU_REM:  alt_mask = 32'h8da68fa5;
      ALU_REMU: alt_mask = 32'h3138d0e1;
      default:  alt_mask = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (prepare_q && !reset) alt_result_q <= (a_q - b_q) ^ alt_mask;
  end

  assign result = alt_result_q;
`else
  logic        signed_op, a_negative, b_negative;
  logic        remainder_op_q, remainder_negative_q, quotient_negative_q;
  logic        divisor_zero_q;
  logic [31:0] dividend_q, divisor_q;

  assign signed_op  = (op_q == ALU_DIV) || (op_q == ALU_REM);
  assign a_negative = signed_op && a_q[31];
  assign b_negative = signed_op && b_q[31];

  // Normalize the divisor into Q0.32, with its leading one at bit 31.
  logic [31:0] normalized, normalized_q;
  logic [4:0]  shift, shift_q;
  logic [31:0] norm16, norm8, norm4, norm2;

  assign shift[4] = divisor_q[31:16] == 16'b0;
  assign norm16   = shift[4] ? {divisor_q[15:0], 16'b0} : divisor_q;
  assign shift[3] = norm16[31:24] == 8'b0;
  assign norm8    = shift[3] ? {norm16[23:0], 8'b0} : norm16;
  assign shift[2] = norm8[31:28] == 4'b0;
  assign norm4    = shift[2] ? {norm8[27:0], 4'b0} : norm8;
  assign shift[1] = norm4[31:30] == 2'b0;
  assign norm2    = shift[1] ? {norm4[29:0], 2'b0} : norm4;
  assign shift[0] = !norm2[31];
  assign normalized = shift[0] ? {norm2[30:0], 1'b0} : norm2;

  logic [12:0] seed;
  div_seed_rom u_seed (
    .clock   (clock),
    .read_en (1'b1),
    .addr    (normalized_q[30:21]),
    .seed    (seed)
  );

  // n0 and e0 use 34 fractional bits. The scaled denominator is rounded
  // up so that e0, its deficit from one, is rounded down.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [44:0] dividend_product;
  logic [34:0] negated_divisor_product;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [34:0] n0_q, n1_q;
  logic [24:0] e0_q;
  logic [14:0] e1_q;
  logic [12:0] factor;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [47:0] n0_product;
  logic [36:0] e0_product;
  logic [49:0] n1_product;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] n2_high_q;

  assign dividend_product        = dividend_q * seed;
  // The low 35 bits of 1 - D_scaled in Q44 are the negated product.
  // Dropping ten bits complements the upper slice with a carry from below.
  assign negated_divisor_product = -(normalized_q * seed);
  // Truncating e0 to 22 fractional bits leaves e0[11:0] as e0 - f
  // in Q34 units. The refined deficit fits in 15 bits.
  assign factor     = e0_q[24:12];
  assign n0_product = n0_q * factor;
  assign e0_product = e0_q * factor;
  assign n1_product = n1_q * e1_q;

  logic [31:0] quotient_q, product_q;
  logic [32:0] dividend_minus_divisor_q;
  logic [31:0] signed_quotient_q, signed_incremented_quotient_q;
  logic        increment_quotient;
  logic [31:0] residual, corrected_residual;
  logic [31:0] uncorrected_base, corrected_base;

  // The datapath advances every cycle. Held launch operands remain stable
  // through completion, and done qualifies the result after update 7.
  always_ff @(posedge clock) begin
    // Preparation captures magnitudes and sign information.
    dividend_q           <= a_negative ? -a_q : a_q;
    divisor_q            <= b_negative ? -b_q : b_q;
    remainder_op_q       <= (op_q == ALU_REM) || (op_q == ALU_REMU);
    remainder_negative_q <= a_negative;
    quotient_negative_q  <= a_negative ^ b_negative;
    divisor_zero_q       <= b_q == 32'b0;

    // Update 1 normalizes the divisor. Update 2 reads the synchronous ROM.
    normalized_q <= normalized;
    shift_q      <= shift;

    // Update 3 multiplies by the reciprocal seed.
    n0_q <= dividend_product[44:10];
    e0_q <= negated_divisor_product[34:10];

    // Update 4 corrects with the truncated first deficit.
    n1_q <= n0_q + {9'b0, n0_product[47:22]};
    e1_q <= {3'b0, e0_q[11:0]} + e0_product[36:22];

    // Update 5 uses the refined deficit and drops the bottom three bits.
    n2_high_q <= 32'((n1_q + {19'b0, n1_product[49:34]}) >> 3);

    // Update 6 denormalizes: n2 >> (34 - s) = (n2 >> 3) >> (31 - s).
    quotient_q               <= n2_high_q >> (~shift_q);
    dividend_minus_divisor_q <= {1'b0, dividend_q} - {1'b0, divisor_q};

    // Update 7 prepares the exact residual check. The estimate is never
    // above A / D, so q * D fits in 32 bits.
    product_q                     <= quotient_q * divisor_q;
    signed_quotient_q             <= quotient_negative_q ? -quotient_q : quotient_q;
    signed_incremented_quotient_q <= quotient_negative_q ? ~quotient_q : quotient_q + 32'd1;
  end

  // The downward estimate can miss the exact quotient by at most one.
  // Use A - D only when its subtraction did not borrow.
  assign increment_quotient = !dividend_minus_divisor_q[32]
                           && product_q <= dividend_minus_divisor_q[31:0];
  assign uncorrected_base = dividend_q;
  assign corrected_base   = dividend_minus_divisor_q[31:0];
  // Form both signed residuals in parallel with the comparison.
  assign residual = (remainder_negative_q ? product_q : uncorrected_base)
                  - (remainder_negative_q ? uncorrected_base : product_q);
  assign corrected_residual = (remainder_negative_q ? product_q : corrected_base)
                            - (remainder_negative_q ? corrected_base : product_q);

  always_comb begin
    if (remainder_op_q) begin
      result = divisor_zero_q ? a_q : (increment_quotient ? corrected_residual : residual);
    end else begin
      // The low word also gives the required INT_MIN / -1 result.
      result = divisor_zero_q ? '1 : (increment_quotient
              ? signed_incremented_quotient_q : signed_quotient_q);
    end
  end
`endif

endmodule
