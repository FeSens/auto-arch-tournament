// Shared blocking RV32M divider. Edge one captures normalized operands;
// edge two peels two bits and registers odd multiples of D. Edges three
// through eight each consume one radix-32 digit: exactly 2 + 6*5 bits.
// DONE exposes sign correction from held state, with earliest transfer at
// edge nine. ALTOPS follows the identical request/completion schedule.
module divider (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 2'd0, ITERATE = 2'd1, DONE = 2'd3;
  logic [1:0] state_q;
  logic [2:0] iteration_q;
  assign req_ready = (state_q == IDLE);
  assign result_valid = (state_q == DONE);

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] a_q, b_q;
  logic [4:0] op_q;
  always_comb begin
    case (op_q)
      ALU_DIV:  result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU: result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:  result = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU: result = (a_q - b_q) ^ 32'h3138d0e1;
      default:  result = '0;
    endcase
  end
`else
  logic signed_op, remainder_op;
  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign remainder_op = (op == ALU_REM || op == ALU_REMU);
  logic [31:0] quotient_q, remainder_q, divisor_q, dividend_q;
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  logic zero_q, overflow_q;
  logic [36:0] odd_multiple_q [1:15]; // indices hold 3D,5D,...,31D
  logic [36:0] divisor_one;
  logic [36:0] multiple [1:31];
  logic [1:0] first_digit, first_remainder;
  assign divisor_one = {5'b0, divisor_q};
  assign multiple[1] = divisor_one;
  for (genvar k = 2; k <= 31; k++) begin : multiples
    if (k % 2 == 0) begin : even_multiple
      assign multiple[k] = multiple[k/2] << 1;
    end else begin : odd_multiple
      assign multiple[k] = odd_multiple_q[k/2];
    end
  end

  // Initially R=0, so the first trial dividend is only h=A[31:30].
  // Decode D=0..3 separately; D>=4 cannot fit into h. This network
  // uses captured normalized operands, outside the main recurrence.
  always_comb begin
    first_digit = 2'd0;
    first_remainder = quotient_q[31:30];
    if (divisor_q[31:2] == 30'b0) begin
      case (divisor_q[1:0])
        2'd0: first_digit = 2'd3; // deterministic; DONE overrides /0
        2'd1: begin
          first_digit = quotient_q[31:30];
          first_remainder = 2'd0;
        end
        2'd2: begin
          first_digit = {1'b0, quotient_q[31]};
          first_remainder = {1'b0, quotient_q[30]};
        end
        2'd3: begin
          first_digit = {1'b0, &quotient_q[31:30]};
          first_remainder = (&quotient_q[31:30]) ? 2'd0 : quotient_q[31:30];
        end
        default: ;
      endcase
    end
  end

  logic [36:0] shifted;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [37:0] trial [1:31];
  /* verilator lint_on UNUSEDSIGNAL */
  logic [32:0] fit;
  logic [31:0] take;
  logic [31:0] remainder_tree [1:63];
  logic [4:0] digit;
  assign shifted = {remainder_q, quotient_q[31:27]};
  assign fit[0] = 1'b1;
  assign fit[32] = 1'b0;
  for (genvar k = 1; k <= 31; k++) begin : trials
    // The high bit is borrow. For D>0, R<D implies T<32D, and the
    // selected remainder fits 32 bits. Preserve all 37 multiple bits.
    assign trial[k] = {1'b0, shifted} - {1'b0, multiple[k]};
    assign fit[k] = !trial[k][37];
  end
  for (genvar k = 0; k < 32; k++) begin : takes
    assign take[k] = fit[k] && !fit[k+1];
    if (k == 0) begin : zero_candidate
      assign remainder_tree[32+k] = {32{take[k]}} & shifted[31:0];
    end else begin : nonzero_candidate
      assign remainder_tree[32+k] = {32{take[k]}} & trial[k][31:0];
    end
  end
  // Explicit five-level balanced masked OR tree; no priority data mux.
  for (genvar k = 1; k < 32; k++) begin : remainder_select
    assign remainder_tree[k] = remainder_tree[2*k] | remainder_tree[2*k+1];
  end
  for (genvar bit_index = 0; bit_index < 5; bit_index++) begin : digit_select
    logic [31:1] tree;
    for (genvar k = 0; k < 16; k++) begin : leaves
      // Insert a set bit at bit_index into the four-bit leaf index.
      localparam integer CANDIDATE = ((k >> bit_index) << (bit_index+1)) |
                                    (1 << bit_index) | (k & ((1 << bit_index)-1));
      assign tree[16+k] = take[CANDIDATE];
    end
    for (genvar k = 1; k < 16; k++) begin : branches
      assign tree[k] = tree[2*k] | tree[2*k+1];
    end
    assign digit[bit_index] = tree[1];
  end

  // Only held state feeds completion. EX/MEM captures this correction;
  // there is no internal corrected-result register or CORRECT cycle.
  always_comb begin
    if (zero_q)
      result = select_remainder_q ? dividend_q : 32'hffffffff;
    else if (overflow_q)
      result = select_remainder_q ? 32'b0 : 32'h80000000;
    else if (select_remainder_q)
      result = remainder_negative_q ? -remainder_q : remainder_q;
    else
      result = quotient_negative_q ? -quotient_q : quotient_q;
  end
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      iteration_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
`else
      quotient_q <= '0;
      remainder_q <= '0;
      divisor_q <= '0;
      for (int k = 1; k <= 15; k++) odd_multiple_q[k] <= '0;
      dividend_q <= '0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
      zero_q <= 1'b0;
      overflow_q <= 1'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (req_valid) begin
          state_q <= ITERATE;
          iteration_q <= '0;
`ifdef RISCV_FORMAL_ALTOPS
          a_q <= a;
          b_q <= b;
          op_q <= op;
`else
          quotient_q <= (signed_op && a[31]) ? -a : a;
          divisor_q <= (signed_op && b[31]) ? -b : b;
          remainder_q <= '0;
          dividend_q <= a;
          quotient_negative_q <= signed_op && (a[31] ^ b[31]);
          remainder_negative_q <= signed_op && a[31];
          select_remainder_q <= remainder_op;
          zero_q <= (b == 32'b0);
          overflow_q <= signed_op && (a == 32'h80000000)
                                  && (b == 32'hffffffff);
`endif
        end
        ITERATE: begin
`ifndef RISCV_FORMAL_ALTOPS
          if (iteration_q == 3'd0) begin
            // Canonical signed-digit forms, each from widened captured D.
            // No serial multiple generation or arithmetic on live inputs.
            odd_multiple_q[1]  <= (divisor_one << 2) - divisor_one;
            odd_multiple_q[2]  <= (divisor_one << 2) + divisor_one;
            odd_multiple_q[3]  <= (divisor_one << 3) - divisor_one;
            odd_multiple_q[4]  <= (divisor_one << 3) + divisor_one;
            odd_multiple_q[5]  <= (divisor_one << 4) - (divisor_one << 2) - divisor_one;
            odd_multiple_q[6]  <= (divisor_one << 4) - (divisor_one << 2) + divisor_one;
            odd_multiple_q[7]  <= (divisor_one << 4) - divisor_one;
            odd_multiple_q[8]  <= (divisor_one << 4) + divisor_one;
            odd_multiple_q[9]  <= (divisor_one << 4) + (divisor_one << 2) - divisor_one;
            odd_multiple_q[10] <= (divisor_one << 4) + (divisor_one << 2) + divisor_one;
            odd_multiple_q[11] <= (divisor_one << 5) - (divisor_one << 3) - divisor_one;
            odd_multiple_q[12] <= (divisor_one << 5) - (divisor_one << 3) + divisor_one;
            odd_multiple_q[13] <= (divisor_one << 5) - (divisor_one << 2) - divisor_one;
            odd_multiple_q[14] <= (divisor_one << 5) - (divisor_one << 2) + divisor_one;
            odd_multiple_q[15] <= (divisor_one << 5) - divisor_one;
            quotient_q <= {quotient_q[29:0], first_digit};
            remainder_q <= {30'b0, first_remainder};
          end else begin
            quotient_q <= {quotient_q[26:0], digit};
            remainder_q <= remainder_tree[1];
          end
`endif
          iteration_q <= iteration_q + 3'd1;
          if (iteration_q == 3'd6) state_q <= DONE;
        end
        DONE: if (result_ready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
