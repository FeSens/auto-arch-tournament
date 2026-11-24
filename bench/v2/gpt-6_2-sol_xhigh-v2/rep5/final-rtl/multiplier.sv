// RV32M multiplier. EX generates the partial products and captures them
// on the EX/MEM handoff. MEM reduces the registered terms.
module multiplier (
  input  logic        clock,
  input  logic        reset,
  input  logic        capture,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] result
);

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
    if (reset)        result <= '0;
    else if (capture) result <= alt_result;
  end
`else
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
  logic [31:0] lo_lo_q, hi_hi_q;
  logic signed [33:0] lo_hi_q, hi_lo_q;
  logic high_half_q;

  assign a_lo = $signed({1'b0, a[15:0]});
  assign b_lo = $signed({1'b0, b[15:0]});
  assign a_hi = $signed({a[31] && (op == ALU_MULH || op == ALU_MULHSU), a[31:16]});
  assign b_hi = $signed({b[31] && op == ALU_MULH, b[31:16]});

  always_ff @(posedge clock) begin
    if (reset) begin
      lo_lo_q     <= '0;
      lo_hi_q     <= '0;
      hi_lo_q     <= '0;
      hi_hi_q     <= '0;
      high_half_q <= 1'b0;
    end else if (capture) begin
      lo_lo_q     <= a_lo * b_lo;
      lo_hi_q     <= a_lo * b_hi;
      hi_lo_q     <= a_hi * b_lo;
      hi_hi_q     <= a_hi * b_hi;
      high_half_q <= op != ALU_MUL;
    end
  end

  // Product bits [15:0] come from lo_lo_q. The four terms below
  // represent bits [63:16], with carries above bit 63 discarded.
  logic [47:0] lo_lo, lo_hi, hi_lo, hi_hi;
  logic [47:0] sum1, carry1, sum2, carry2, upper;

  assign lo_lo = {32'b0, lo_lo_q[31:16]};
  assign lo_hi = {{14{lo_hi_q[33]}}, lo_hi_q};
  assign hi_lo = {{14{hi_lo_q[33]}}, hi_lo_q};
  assign hi_hi = {hi_hi_q, 16'b0};

  assign sum1   = lo_lo ^ lo_hi ^ hi_lo;
  assign carry1 = ((lo_lo & lo_hi) | (lo_lo & hi_lo) | (lo_hi & hi_lo)) << 1;
  assign sum2   = sum1 ^ carry1 ^ hi_hi;
  assign carry2 = ((sum1 & carry1) | (sum1 & hi_hi) | (carry1 & hi_hi)) << 1;
  assign upper  = sum2 + carry2;
  assign result = high_half_q ? upper[47:16] : {upper[15:0], lo_lo_q[15:0]};
`endif

endmodule
