// The low word is combinational. A high-word operation captures its
// intermediates at launch, then registers the corrected word one cycle later.
module mul_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        consume,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        ready,
  output logic        done,
  output logic [31:0] low_result,
  output logic [31:0] high_result
);

  logic        active_q;
  logic        launch, finish;
  logic [31:0] corrected_high;

  assign ready  = !active_q;
  assign launch = start && ready;
  assign finish = active_q && !done;

  always_ff @(posedge clock) begin
    if (reset) begin
      active_q <= 1'b0;
      done     <= 1'b0;
    end else if (launch) begin
      active_q <= 1'b1;
    end else if (finish) begin
      done     <= 1'b1;
    end else if (done && consume) begin
      active_q <= 1'b0;
      done     <= 1'b0;
    end

    if (finish) high_result <= corrected_high;
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Substitute the formal arithmetic while keeping both timing paths.
  logic [31:0] alt_high, alt_high_q;

  assign low_result = (a + b) ^ 32'h5876063e;
  always_comb begin
    case (op)
      ALU_MULH:   alt_high = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_high = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_high = (a - b) ^ 32'hecfbe137;
      default:    alt_high = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (launch) alt_high_q <= alt_high;
  end

  assign corrected_high = alt_high_q;
`else
  logic [63:0] product;
  logic        a_negative, b_negative;
  logic [31:0] unsigned_high_q, correction_q;

  assign product    = a * b;
  assign low_result = product[31:0];
  assign a_negative = ((op == ALU_MULH) || (op == ALU_MULHSU)) && a[31];
  assign b_negative = (op == ALU_MULH) && b[31];

  // A negative signed operand subtracts one copy of the other operand
  // from the high word. The two terms add modulo 2^32.
  always_ff @(posedge clock) begin
    if (launch) begin
      unsigned_high_q <= product[63:32];
      correction_q    <= (a_negative ? b : 32'b0) + (b_negative ? a : 32'b0);
    end
  end

  assign corrected_high = unsigned_high_q - correction_q;
`endif

endmodule
