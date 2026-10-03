// Blocking RV32M multiplier. The accepted request computes directly from
// registered EX inputs into one response register, with no preparation cycle.
// A pending response is held until accepted and rejects further requests.
module mul_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  req_op,
  input  logic [31:0] req_a,
  input  logic [31:0] req_b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  logic valid_q;
  logic [31:0] result_q, request_result;

  assign req_ready = !valid_q && !reset;
  assign result_valid = valid_q && !reset;
  assign result = result_q;

`ifndef RISCV_FORMAL_ALTOPS
  logic signed [32:0] extended_a, extended_b;
  // Bits 65:64 are sign extension; RV32M selects bits 63:32 or 31:0.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] product;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    extended_a = $signed({((req_op == ALU_MULH || req_op == ALU_MULHSU)
                          && req_a[31]), req_a});
    extended_b = $signed({(req_op == ALU_MULH && req_b[31]), req_b});
    product = extended_a * extended_b;
  end
`endif

  always_comb begin
    case (req_op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    request_result = (req_a + req_b) ^ 32'h5876063e;
      ALU_MULH:   request_result = (req_a + req_b) ^ 32'hf6583fb7;
      ALU_MULHU:  request_result = (req_a + req_b) ^ 32'h949ce5e8;
      ALU_MULHSU: request_result = (req_a - req_b) ^ 32'hecfbe137;
`else
      ALU_MUL:    request_result = product[31:0];
      ALU_MULH, ALU_MULHU, ALU_MULHSU: request_result = product[63:32];
`endif
      default: request_result = '0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= 1'b0;
      result_q <= '0;
    end else if (req_valid && req_ready) begin
      result_q <= request_result;
      valid_q <= 1'b1;
    end else if (result_valid && result_ready) begin
      valid_q <= 1'b0;
    end
  end
endmodule
