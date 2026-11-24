// Blocking RV32M divider. After issue, one edge sets up the selected lane
// and six edges are reserved for its computation before EX/MEM accepts it.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        issue,
  output logic        issue_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result,
  output logic [31:0] src_a,
  output logic [31:0] src_b
);

  localparam logic [3:0] IDLE = 4'd0;
  localparam logic [3:0] SETUP = 4'd1;
  localparam logic [3:0] COMPLETE = 4'd8;

  logic [3:0] phase_q;
  assign issue_ready = (phase_q == IDLE);
  assign result_valid = (phase_q == COMPLETE);

  always_ff @(posedge clock) begin
    if (reset) begin
      phase_q <= IDLE;
    end else if (issue_ready) begin
      if (issue) phase_q <= SETUP;
    end else if (result_valid) begin
      if (result_ready) phase_q <= IDLE;
    end else begin
      phase_q <= phase_q + 4'd1;
    end
  end

  // Keep the original forwarded operands for RVFI and zero-divisor REM.
  always_ff @(posedge clock) begin
    if (issue && issue_ready) begin
      src_a <= a;
      src_b <= b;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_mask;
  always_comb begin
    case (op)
      ALU_DIV:  alt_mask = 32'h7f8529ec;
      ALU_DIVU: alt_mask = 32'h10e8fd70;
      ALU_REM:  alt_mask = 32'h8da68fa5;
      ALU_REMU: alt_mask = 32'h3138d0e1;
      default:  alt_mask = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (issue && issue_ready) result <= (a - b) ^ alt_mask;
  end
`else
  localparam logic [3:0] FIRST_GROUP = 4'd2;

  logic signed_op, remainder_op;
  logic a_negative, b_negative;
  logic remainder_op_q, negate_q, divide_by_zero_q;
  logic wide_divisor, wide_q;
  logic [31:0] dividend_abs_q, divisor_abs_q;
  logic [35:0] d, d_times_2, d_times_4, d_times_8, d_times_16;
  logic [35:0] multiple_q [1:15];
  logic [31:0] narrow_quotient_q, narrow_result_q;
  logic [23:0] wide_dividend_quotient_q;
  logic [7:0] narrow_remainder_q;
  logic [31:0] wide_remainder_q;
  logic [31:0] magnitude, corrected;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign remainder_op = (op == ALU_REM || op == ALU_REMU);
  assign a_negative = signed_op && a[31];
  assign b_negative = signed_op && b[31];
  assign wide_divisor = |divisor_abs_q[31:8];

  assign d          = {4'b0, divisor_abs_q};
  assign d_times_2  = {3'b0, divisor_abs_q, 1'b0};
  assign d_times_4  = {2'b0, divisor_abs_q, 2'b0};
  assign d_times_8  = {1'b0, divisor_abs_q, 3'b0};
  assign d_times_16 = {divisor_abs_q, 4'b0};

  // Compress three shifted copies to a sum and a carry before the adder.
  function automatic [35:0] add_three(
    input logic [35:0] x, y, z
  );
    add_three = (x ^ y ^ z) + (((x & y) | (x & z) | (y & z)) << 1);
  endfunction

  // In two's-complement negation, a bit flips iff a lower bit is set.
  function automatic [31:0] conditional_negate(
    input logic [31:0] value,
    input logic negate
  );
    conditional_negate[0] = value[0];
    for (int bit_idx = 1; bit_idx < 32; bit_idx++) begin
      conditional_negate[bit_idx] = value[bit_idx] ^ (negate && |(value << (32 - bit_idx)));
    end
  endfunction

  // Multiplying by floor(2**32 / D) estimates the quotient to within one.
  // The remainder before correction is below 2D, so nine bits suffice
  // for both the scaled estimate and the subtraction. Saturating the
  // reciprocal for D=1 also puts its estimate within one.
  wire [31:0] recip_rom [0:255];
  logic [31:0] reciprocal_q, estimate_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] reciprocal_product_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [8:0] scaled_q, remainder_estimate_q;
  logic [8:0] remainder_minus_divisor;

  assign recip_rom[0] = 32'b0;
  assign recip_rom[1] = 32'hffff_ffff;
  for (genvar divisor = 2; divisor < 256; divisor++) begin : gen_reciprocal
    assign recip_rom[divisor] = 32'(33'h1_0000_0000 / 33'(divisor));
  end

  assign remainder_minus_divisor = remainder_estimate_q - {1'b0, divisor_abs_q[7:0]};

  always_ff @(posedge clock) begin
    case (phase_q)
      SETUP: reciprocal_q <= recip_rom[divisor_abs_q[7:0]];
      4'd2: reciprocal_product_q <= dividend_abs_q * reciprocal_q;
      4'd3: begin
        estimate_q <= reciprocal_product_q[63:32];
        scaled_q <= reciprocal_product_q[40:32] * divisor_abs_q[7:0];
      end
      4'd4: remainder_estimate_q <= dividend_abs_q[8:0] - scaled_q;
      4'd5: begin
        narrow_quotient_q <= estimate_q + {31'b0, !remainder_minus_divisor[8]};
        narrow_remainder_q <= remainder_minus_divisor[8] ? remainder_estimate_q[7:0]
                                                        : remainder_minus_divisor[7:0];
      end
      4'd6: narrow_result_q <= conditional_negate(
        remainder_op_q ? {24'b0, narrow_remainder_q} : narrow_quotient_q, negate_q
      );
      default: ;
    endcase
  end

  // Appending four bits to a remainder below D gives a trial below 16D.
  // Adjacent borrows select the largest multiple at or below the trial.
  logic [35:0] wide_trial;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [36:0] wide_diff [1:15];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [16:0] wide_borrow;
  logic [15:0] wide_select;
  logic [31:0] wide_remainder_next;
  logic [3:0] wide_digit;

  assign wide_trial = {wide_remainder_q, wide_dividend_quotient_q[23:20]};
  assign wide_borrow[0] = 1'b0;
  assign wide_borrow[16] = 1'b1;
  for (genvar digit = 1; digit < 16; digit++) begin : gen_wide_diff
    assign wide_diff[digit] = {1'b0, wide_trial} - {1'b0, multiple_q[digit]};
    assign wide_borrow[digit] = wide_diff[digit][36];
  end
  for (genvar digit = 0; digit < 16; digit++) begin : gen_wide_select
    assign wide_select[digit] = !wide_borrow[digit] && wide_borrow[digit + 1];
  end
  for (genvar bit_idx = 0; bit_idx < 32; bit_idx++) begin : gen_wide_remainder
    logic [15:0] selected_bits;
    assign selected_bits[0] = wide_trial[bit_idx] & wide_select[0];
    for (genvar digit = 1; digit < 16; digit++) begin : gen_candidate
      assign selected_bits[digit] = wide_diff[digit][bit_idx] & wide_select[digit];
    end
    assign wide_remainder_next[bit_idx] = |selected_bits;
  end

  // Each mask picks the one-hot positions where that quotient bit is set.
  assign wide_digit[0] = |(wide_select & 16'haaaa);
  assign wide_digit[1] = |(wide_select & 16'hcccc);
  assign wide_digit[2] = |(wide_select & 16'hf0f0);
  assign wide_digit[3] = |(wide_select & 16'hff00);

  always_ff @(posedge clock) begin
    if (issue && issue_ready) begin
      dividend_abs_q <= conditional_negate(a, a_negative);
      divisor_abs_q <= conditional_negate(b, b_negative);
      remainder_op_q <= remainder_op;
      negate_q <= a_negative ^ (b_negative && !remainder_op);
    end else if (phase_q == SETUP) begin
      wide_q <= wide_divisor;
      divide_by_zero_q <= (divisor_abs_q == 32'b0);
      multiple_q[1]  <= d;
      multiple_q[2]  <= d_times_2;
      multiple_q[3]  <= d_times_2 + d;
      multiple_q[4]  <= d_times_4;
      multiple_q[5]  <= d_times_4 + d;
      multiple_q[6]  <= d_times_4 + d_times_2;
      multiple_q[7]  <= d_times_8 - d;
      multiple_q[8]  <= d_times_8;
      multiple_q[9]  <= d_times_8 + d;
      multiple_q[10] <= d_times_8 + d_times_2;
      multiple_q[11] <= add_three(d_times_8, d_times_2, d);
      multiple_q[12] <= d_times_8 + d_times_4;
      multiple_q[13] <= add_three(d_times_8, d_times_4, d);
      multiple_q[14] <= d_times_16 - d_times_2;
      multiple_q[15] <= d_times_16 - d;

      if (wide_divisor) begin
        // D >= 256 guarantees this prefix fits and contributes zero
        // quotient bits. The six radix-16 digits fill the low 24 bits.
        wide_remainder_q <= {24'b0, dividend_abs_q[31:24]};
        wide_dividend_quotient_q <= dividend_abs_q[23:0];
      end
    end else if (phase_q >= FIRST_GROUP && phase_q < COMPLETE) begin
      if (wide_q) begin
        wide_remainder_q <= wide_remainder_next;
        wide_dividend_quotient_q <= {wide_dividend_quotient_q[19:0], wide_digit};
      end
    end
  end

  assign magnitude = remainder_op_q ? wide_remainder_q : {8'b0, wide_dividend_quotient_q};
  assign corrected = conditional_negate(magnitude, negate_q);

  always_comb begin
    if (divide_by_zero_q)
      result = remainder_op_q ? src_a : 32'hffff_ffff;
    else
      result = wide_q ? corrected : narrow_result_q;
  end
`endif

endmodule
