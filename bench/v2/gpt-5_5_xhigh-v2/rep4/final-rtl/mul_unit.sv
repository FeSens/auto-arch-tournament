// rtl/mul_unit.sv
//
// Registered low-half RV32M multiplier. EX starts this sidecar for MUL and
// holds the instruction for one cycle while the DSP product is captured outside
// the hot combinational ALU cone.
module mul_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [31:0] lhs,
  input  logic [31:0] rhs,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);

  logic        done_q;
  logic [31:0] result_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      done_q   <= 1'b0;
      result_q <= 32'b0;
    end else begin
      if (accept && done_q) begin
        done_q <= 1'b0;
      end

      if (start && !done_q) begin
        result_q <= lhs * rhs;
        done_q   <= 1'b1;
      end
    end
  end

  assign busy   = 1'b0;
  assign done   = done_q;
  assign result = result_q;

endmodule
