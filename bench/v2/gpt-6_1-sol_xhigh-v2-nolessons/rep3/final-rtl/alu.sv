// rtl/alu.sv
//
// RV32IM integer ALU, with shared clocked multiply and divide units.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        integer combinational; all M operations use valid/ready.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu #(
  // Standalone users retain encoded selection. The core supplies registered
  // integer/link grants and selects the exclusively owned M completion.
  /* verilator lint_off UNUSEDPARAM */
  parameter bit SEPARATE_M = 1'b0,
  parameter bit PREDECODED_RESULT = 1'b0
  /* verilator lint_on UNUSEDPARAM */
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clock,
  input  logic        reset,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        div_req_valid,
  output logic        div_req_ready,
  output logic        div_result_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        div_result_ready,
  input  logic        m_is_multiply,
  input  logic        m_is_divide,
  input  logic [11:0] result_grants,
  input  logic [31:0] pc_plus4,
  input  logic        m_complete,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] m_result,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  assign shamt = b[4:0];

`ifdef RISCV_FORMAL_ALTOPS
  // EX uses the single-cycle ALTOPS out path; no iterative unit is reachable.
  assign div_req_ready = 1'b1;
  assign div_result_valid = div_req_valid;
  assign m_result = out;
`else
  logic is_multiply, is_divide;
  logic mul_req_ready, mul_result_valid;
  logic divider_req_ready, divider_result_valid;
  logic [31:0] mul_result;
  logic [31:0] div_quotient, div_remainder;
  logic div_result_rem;
  logic m_active_q, owner_multiply_q;
  logic mul_consume, div_consume;
  assign is_multiply = SEPARATE_M ? m_is_multiply :
                      (op == ALU_MUL || op == ALU_MULH ||
                       op == ALU_MULHU || op == ALU_MULHSU);
  assign is_divide = SEPARATE_M ? m_is_divide :
                    (op == ALU_DIV || op == ALU_DIVU ||
                     op == ALU_REM || op == ALU_REMU);
  assign div_req_ready = (!SEPARATE_M || !m_active_q) &&
                        (is_multiply ? mul_req_ready
                                     : (is_divide && divider_req_ready));
  // Core dispatch permits only one outstanding operation. Its exclusive
  // units combine completion independently of the consumer's live opcode.
  assign div_result_valid = SEPARATE_M ? (mul_result_valid || divider_result_valid)
                          : (is_multiply ? mul_result_valid
                                         : (is_divide && divider_result_valid));
  assign mul_consume = div_result_ready && (SEPARATE_M
                     ? (m_active_q && owner_multiply_q) : is_multiply);
  assign div_consume = div_result_ready && (SEPARATE_M
                     ? (m_active_q && !owner_multiply_q) : is_divide);
  assign m_result = owner_multiply_q ? mul_result
                  : (div_result_rem ? div_remainder : div_quotient);

  always_ff @(posedge clock) begin
    if (reset) begin
      m_active_q <= 1'b0;
      owner_multiply_q <= 1'b0;
    end else begin
      if (div_req_valid && div_req_ready) begin
        m_active_q <= 1'b1;
        owner_multiply_q <= is_multiply;
      end
      if (div_result_valid && div_result_ready) m_active_q <= 1'b0;
    end
  end
  multiplier u_multiplier (
    .clock        (clock),
    .reset        (reset),
    .req_valid    (div_req_valid && div_req_ready && is_multiply),
    .req_ready    (mul_req_ready),
    .req_op       (op),
    .a            (a),
    .b            (b),
    .result_valid (mul_result_valid),
    .result_ready (mul_consume),
    .result       (mul_result)
  );
  divider u_divider (
    .clock        (clock),
    .reset        (reset),
    .req_valid    (div_req_valid && div_req_ready && is_divide),
    .req_ready    (divider_req_ready),
    .req_signed   (op == ALU_DIV || op == ALU_REM),
    .req_rem      (op == ALU_REM || op == ALU_REMU),
    .dividend     (a),
    .divisor      (b),
    .result_valid (divider_result_valid),
    .result_ready (div_consume),
    .result_rem   (div_result_rem),
    .quotient     (div_quotient),
    .remainder    (div_remainder)
  );
`endif

  generate if (PREDECODED_RESULT) begin : gen_predecoded_result
    // Shift grants enter before the original barrel expressions. In
    // particular SRA masks before the signed cast, so an unused negative
    // operand cannot contribute sign-fill bits to the parallel result OR.
`ifdef RISCV_FORMAL_ALTOPS
    always_comb begin
`else
    assign
`endif
    out = ((((a + b) & {32{result_grants[0]}})
         | ((a - b) & {32{result_grants[1]}}))
        | (((a & b) & {32{result_grants[2]}})
         | ((a | b) & {32{result_grants[3]}}))
        | (((a ^ b) & {32{result_grants[4]}})
         | ({31'b0, $signed(a) < $signed(b)} & {32{result_grants[5]}})
         | ({31'b0, a < b} & {32{result_grants[6]}}))
        | ((b & {32{result_grants[10]}})
         | (pc_plus4 & {32{result_grants[11]}}))
`ifndef RISCV_FORMAL_ALTOPS
        | ({32{m_complete}} & m_result)
`endif
        )
        | ((a & {32{result_grants[7]}}) << shamt)
        | ((a & {32{result_grants[8]}}) >> shamt)
        | $unsigned($signed(a & {32{result_grants[9]}}) >>> shamt);
`ifdef RISCV_FORMAL_ALTOPS
    // Only M opcodes override the registered-grant datapath in formal.
    // There is no service ownership or completion in this build.
    case (op)
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
      default: ;
    endcase
    end
`endif
  end else begin : gen_encoded_result
  always_comb begin
    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = a << shamt;
      ALU_SRL:    out = a >> shamt;
      ALU_SRA:    out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    out = b;

      // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
      // are substituted for tractable algebraic stand-ins so bitwuzla
      // can solve the BMC inside the 20-step depth budget. The same
      // substitution must appear in the riscv-formal spec (insn_*.v).
      // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
      // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
`else
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU:
                   out = SEPARATE_M ? 32'b0 : mul_result;
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
                   out = SEPARATE_M ? 32'b0
                       : (div_result_rem ? div_remainder : div_quotient);
`endif
      default:  out = 32'b0;
    endcase
  end
  end endgenerate

endmodule
