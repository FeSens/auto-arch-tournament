// Blocking RV32M multiplier. The partial products are registered at launch.
module mul_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        request_valid,
  output logic        request_ready,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);

  typedef enum logic [1:0] {IDLE, PRODUCTS, HIGH_RESULT} phase_t;
  phase_t phase_q;
  logic capture, high_half_q;

  assign request_ready = (phase_q == IDLE);
  assign capture = request_valid && request_ready;
  assign result_valid = (phase_q == PRODUCTS && !high_half_q) ||
                        (phase_q == HIGH_RESULT);

  // A low half can transfer on the edge after launch. A high half uses
  // that edge to register its cross-term carry and transfers one edge later.
  always_ff @(posedge clock) begin
    if (reset) begin
      phase_q <= IDLE;
    end else if (capture) begin
      phase_q <= PRODUCTS;
      high_half_q <= (op != ALU_MUL);
    end else if (phase_q == PRODUCTS && high_half_q) begin
      phase_q <= HIGH_RESULT;
    end else if (result_valid && result_ready) begin
      phase_q <= IDLE;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;
  always_comb begin
    case (op)
      ALU_MUL:    alt_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   alt_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_result = (a - b) ^ 32'hecfbe137;
      default:    alt_result = '0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (capture)
      result <= alt_result;
  end
`else
  logic signed [16:0] a_lo, b_lo, a_hi, b_hi;
  logic        [31:0] low_low_q, high_high_q;
  logic signed [33:0] low_high_q, high_low_q;
  logic        [33:0] low_carry, sum_bits, carry_bits;
  logic signed [33:0] middle;
  logic        [31:0] middle_high_q;

  assign a_lo = $signed({1'b0, a[15:0]});
  assign b_lo = $signed({1'b0, b[15:0]});
  assign a_hi = $signed({a[31] && (op == ALU_MULH || op == ALU_MULHSU), a[31:16]});
  assign b_hi = $signed({b[31] && (op == ALU_MULH), b[31:16]});

  // Compress the two signed cross products and the unsigned low-product
  // carry before the single carry-propagate addition.
  assign low_carry  = {18'b0, low_low_q[31:16]};
  assign sum_bits   = low_high_q ^ high_low_q ^ low_carry;
  assign carry_bits = ((low_high_q & high_low_q) |
                       ((low_high_q | high_low_q) & low_carry)) << 1;
  assign middle = $signed(sum_bits + carry_bits);

  always_ff @(posedge clock) begin
    if (capture) begin
      low_low_q   <= a_lo * b_lo;
      low_high_q  <= a_lo * b_hi;
      high_low_q  <= a_hi * b_lo;
      high_high_q <= a_hi * b_hi;
    end
    if (phase_q == PRODUCTS && high_half_q)
      middle_high_q <= {{14{middle[33]}}, middle[33:16]};
  end

  assign result = high_half_q ? high_high_q + middle_high_q
                              : {middle[15:0], low_low_q[15:0]};
`endif

endmodule
