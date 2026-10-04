`include "core_pkg.sv"
// Verification-only X -> EX/MEM -> M -> W arithmetic composition.
module alu_test_top (
  input logic clock, reset, div_request, div_consume,
  input logic [4:0] op,
  input logic [31:0] a, b,
  output logic div_busy, div_valid,
  output logic [31:0] out, div_result,
  output logic m_valid, w_valid,
  output logic [31:0] w_result
);
  logic [31:0] ordinary, finished;
  mul_partial_t mul_partial, mul_q;
  div_token_t div_token, div_q;
  logic [1:0] kind_q;
  alu u_alu (
    .clock(clock), .reset(reset), .div_request(div_request),
    .div_consume(div_consume), .div_busy(div_busy), .div_valid(div_valid),
    .div_token(div_token), .mul_partial(mul_partial),
    .op(op), .a(a), .b(b), .out(ordinary)
  );
  m_finish u_finish (
    .kind(kind_q), .mul_partial(mul_q), .div_token(div_q), .result(finished)
  );
  always_ff @(posedge clock) begin
    mul_q <= mul_partial;
    if (div_valid && div_consume) div_q <= div_token;
    w_result <= finished;
    if (reset) begin
      kind_q <= M_NONE;
      m_valid <= 1'b0;
      w_valid <= 1'b0;
    end else begin
      w_valid <= m_valid;
      m_valid <= div_valid && div_consume;
      kind_q <= div_valid && div_consume ? M_DIV : M_MUL;
    end
  end
  assign out = (op >= ALU_MUL && op <= ALU_MULHSU) ? finished : ordinary;
  assign div_result = finished;
endmodule
