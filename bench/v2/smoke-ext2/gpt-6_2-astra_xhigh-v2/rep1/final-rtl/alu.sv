// rtl/alu.sv
//
// DIV[U] and REM[U] share a restoring divider. div_start captures operands
// on the issue edge. div_done marks the eighth round, when EX can latch
// div_result on the upcoming edge. All other ALU operations are combinational.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        div_start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] div_result
);

  logic [3:0] rounds_left;
  assign div_busy = rounds_left != 4'd0;
  assign div_done = rounds_left == 4'd1;

  always_ff @(posedge clock) begin
    if (reset)          rounds_left <= 4'd0;
    else if (div_start) rounds_left <= 4'd8;
    else if (div_busy)  rounds_left <= rounds_left - 4'd1;
  end

`ifdef RISCV_FORMAL_ALTOPS
  // Sample the formal substitute at the same edge as the hardware operands.
  always_ff @(posedge clock) begin
    if (div_start) begin
      case (op)
        ALU_DIV:  div_result <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: div_result <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  div_result <= (a - b) ^ 32'h8da68fa5;
        default:  div_result <= (a - b) ^ 32'h3138d0e1; // REMU
      endcase
    end
  end
`else
  logic signed_op, remainder_op;
  logic [31:0] divisor_q, quotient_q, remainder_q;
  logic want_remainder_q, negate_q, special_q;

  assign signed_op = op == ALU_DIV || op == ALU_REM;
  assign remainder_op = op == ALU_REM || op == ALU_REMU;

  logic [31:0] next_quotient, next_remainder, magnitude;
  logic [32:0] difference;
  always_comb begin
    next_quotient = quotient_q;
    next_remainder = remainder_q;
    for (int i = 0; i < 4; i++) begin
      // The remainder is at most the dividend prefix consumed so far.
      // Before each shift that prefix has at most 31 bits, so the trial
      // fits in 32 bits and bit 32 of the subtraction is the borrow.
      next_remainder = {next_remainder[30:0], next_quotient[31]};
      difference = {1'b0, next_remainder} - {1'b0, divisor_q};
      if (!difference[32]) next_remainder = difference[31:0];
      next_quotient = {next_quotient[30:0], !difference[32]};
    end
    magnitude = want_remainder_q ? next_remainder : next_quotient;
    div_result = special_q ? quotient_q : (negate_q ? -magnitude : magnitude);
  end

  always_ff @(posedge clock) begin
    if (div_start) begin
      divisor_q <= signed_op && b[31] ? -b : b;
      remainder_q <= '0;
      want_remainder_q <= remainder_op;
      negate_q <= signed_op && (a[31] ^ (!remainder_op && b[31]));

      // Keep exceptional results in the quotient register for all eight
      // rounds. Both quotient overflow and division by zero are defined.
      if (b == 0) begin
        special_q <= 1'b1;
        quotient_q <= remainder_op ? a : 32'hffff_ffff;
      end else if (signed_op && a == 32'h8000_0000 && b == 32'hffff_ffff) begin
        special_q <= 1'b1;
        quotient_q <= remainder_op ? 32'b0 : 32'h8000_0000;
      end else begin
        special_q <= 1'b0;
        quotient_q <= signed_op && a[31] ? -a : a;
      end
    end else if (div_busy && !special_q) begin
      quotient_q <= next_quotient;
      remainder_q <= next_remainder;
    end
  end
`endif

  logic        [4:0]  shamt;

  // 64-bit products, computed once and selected per op.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

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
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
