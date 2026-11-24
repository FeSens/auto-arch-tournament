// The EX multiplier takes forwarded register values directly and latches
// its architectural word on issue. The divider has its own refinement DSP.
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
  input  logic        mul_issue,
  input  logic [31:0] mul_rs1,
  input  logic [31:0] mul_rs2,
  output logic [31:0] mem_product,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_result_valid,
  input  logic        div_result_ready,
  output logic [31:0] div_result
);

  always_comb begin
    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = a << b[4:0];
      ALU_SRL:    out = a >> b[4:0];
      ALU_SRA:    out = $unsigned($signed(a) >>> b[4:0]);
      ALU_LUI:    out = b;
      default:    out = '0;
    endcase
  end

  logic [31:0] product_word;
`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    case (op)
      ALU_MUL:    product_word = (mul_rs1 + mul_rs2) ^ 32'h5876063e;
      ALU_MULH:   product_word = (mul_rs1 + mul_rs2) ^ 32'hf6583fb7;
      ALU_MULHU:  product_word = (mul_rs1 + mul_rs2) ^ 32'h949ce5e8;
      ALU_MULHSU: product_word = (mul_rs1 - mul_rs2) ^ 32'hecfbe137;
      default:    product_word = '0;
    endcase
  end
`else
  logic signed [32:0] mul_a, mul_b;
  logic [63:0] full_product;
  assign mul_a = {mul_rs1[31] && (op == ALU_MULH || op == ALU_MULHSU), mul_rs1};
  assign mul_b = {mul_rs2[31] && op == ALU_MULH, mul_rs2};
  assign full_product = mul_a * mul_b;
  assign product_word = op == ALU_MUL ? full_product[31:0] : full_product[63:32];
`endif
  always_ff @(posedge clock) begin
    if (mul_issue)
      mem_product <= product_word;
  end

  logic       busy_q;
  logic [2:0] pass_q;
  logic       div_issue;
  assign div_req_ready = !busy_q && !div_result_valid;
  assign div_issue = div_req_valid && div_req_ready;

  always_ff @(posedge clock) begin
    if (reset) begin
      busy_q           <= 1'b0;
      pass_q           <= '0;
      div_result_valid <= 1'b0;
    end else if (div_issue) begin
      busy_q <= 1'b1;
      pass_q <= '0;
    end else if (busy_q) begin
      pass_q <= pass_q + 3'd1;
      if (pass_q == 3'd6) begin
        busy_q           <= 1'b0;
        div_result_valid <= 1'b1;
      end
    end else if (div_result_ready) begin
      div_result_valid <= 1'b0;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_a_q, alt_b_q;
  logic [4:0]  alt_op_q;
  always_ff @(posedge clock) begin
    if (div_issue) begin
      alt_a_q  <= a;
      alt_b_q  <= b;
      alt_op_q <= op;
    end
  end
  always_comb begin
    div_result  = '0;
    case (alt_op_q)
      ALU_DIV:    div_result  = (alt_a_q - alt_b_q) ^ 32'h7f8529ec;
      ALU_DIVU:   div_result  = (alt_a_q - alt_b_q) ^ 32'h10e8fd70;
      ALU_REM:    div_result  = (alt_a_q - alt_b_q) ^ 32'h8da68fa5;
      ALU_REMU:   div_result  = (alt_a_q - alt_b_q) ^ 32'h3138d0e1;
      default: ;
    endcase
  end
`else
  logic [31:0] dividend, divisor;
  logic        want_rem_q, negate_q, zero_q;
  logic        signed_op, a_negative, b_negative, want_rem;
  assign signed_op  = op == ALU_DIV || op == ALU_REM;
  assign a_negative = signed_op && a[31];
  assign b_negative = signed_op && b[31];
  assign want_rem   = op == ALU_REM || op == ALU_REMU;

  always_ff @(posedge clock) begin
    if (div_issue) begin
      dividend   <= a_negative ? -a : a;
      divisor    <= b_negative ? -b : b;
      negate_q   <= want_rem ? a_negative : a_negative ^ b_negative;
      want_rem_q <= want_rem;
      zero_q     <= b == 0;
    end
  end

  // Shift the highest set bit to bit 31. Each stage also produces one
  // bit of clz(B), so its complement gives k = floor(log2(B)).
  logic [4:0]  clz_b, k_q;
  logic [31:0] norm16, norm8, norm4, norm2, normalized, normalized_q;
  assign clz_b[4] = divisor[31:16] == 0;
  assign norm16 = clz_b[4] ? divisor << 16 : divisor;
  assign clz_b[3] = norm16[31:24] == 0;
  assign norm8 = clz_b[3] ? norm16 << 8 : norm16;
  assign clz_b[2] = norm8[31:28] == 0;
  assign norm4 = clz_b[2] ? norm8 << 4 : norm8;
  assign clz_b[1] = norm4[31:30] == 0;
  assign norm2 = clz_b[1] ? norm4 << 2 : norm4;
  assign clz_b[0] = !norm2[31];
  assign normalized = clz_b[0] ? norm2 << 1 : norm2;

  // Lower-bound reciprocal at the upper end of each of 512 bins.
  // The division in this ROM initializer is evaluated at elaboration.
  logic [11:0] seed [0:511];
  initial begin
    for (int i = 0; i < 512; i++)
      seed[i] = 12'(2097152 / (513 + i));
  end

  logic [33:0] recip_q;       // R scaled by S = 2^34
  logic [34:0] factor_q;      // E can exceed S
  logic [32:0] a_minus_b_q;   // bit 32 is the borrow from A-B
  logic [31:0] quotient_q, raw_product_q, bumped_q;
  logic signed [35:0] dsp_a, dsp_b;
  // The largest refinement needs bits 67:34.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [71:0] product;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    dsp_b = pass_q == 3'd6 ? {4'b0, divisor} : {2'b0, recip_q};
    case (pass_q)
      3'd2, 3'd4: dsp_a = {1'b0, factor_q};
      3'd6:       dsp_a = {4'b0, quotient_q};
      default:    dsp_a = {4'b0, normalized_q};
    endcase
  end
  assign product = dsp_a * dsp_b;

  always_ff @(posedge clock) begin
    if (busy_q) begin
      case (pass_q)
        3'd0: begin
          normalized_q <= normalized;
          k_q          <= ~clz_b;
          recip_q      <= {seed[normalized[30:22]], 22'b0};
        end
        // E = 2*S - 1 - floor(D*R / 2^31), then R = floor(R*E / S).
        3'd1, 3'd3: begin
          factor_q    <= ~product[65:31];
          a_minus_b_q <= {1'b0, dividend} - {1'b0, divisor};
        end
        3'd2: recip_q <= product[67:34];
        3'd4: begin
          recip_q      <= product[67:34];
          // The last refinement has consumed the normalized divisor.
          // Reuse its register for pass 5, shifting ahead of the DSP.
          normalized_q <= dividend >> k_q;
        end
        3'd5: quotient_q <= product[65:34];
        3'd6: begin
          raw_product_q <= product[31:0];
          bumped_q      <= quotient_q + (negate_q ? 32'hffff_ffff : 32'd1);
        end
        default: ;
      endcase
    end
  end

  // For B > 0, dropping k dividend bits costs at most 1 - 2^-k
  // quotient units. The lower-bound reciprocal costs less than 2^-k
  // more, so the estimate is floor(A/B) or one less.
  // Thus P = Q*B fits in 32 bits. A-P >= B iff A >= B and P <= A-B.
  logic        correct;
  logic [31:0] r0, r1, q, word;
  assign correct = !a_minus_b_q[32] && raw_product_q <= a_minus_b_q[31:0];

  // For a negative result, form magnitude-1 so the final XOR gives -magnitude.
  // Both remainder candidates and the correction comparison run in parallel.
  assign r0 = dividend          + ~raw_product_q + {31'b0, !negate_q};
  assign r1 = a_minus_b_q[31:0] + ~raw_product_q + {31'b0, !negate_q};
  assign q = (correct ^ negate_q) ? bumped_q : quotient_q;
  assign word = ({32{want_rem_q && !correct}} & r0) |
                ({32{want_rem_q && correct}} & r1) |
                ({32{!want_rem_q}} & q);
  // At B=0, P=0 and both remainder candidates restore the dividend.
  assign div_result = !want_rem_q && zero_q ? 32'hffff_ffff : word ^ {32{negate_q}};
`endif

endmodule
