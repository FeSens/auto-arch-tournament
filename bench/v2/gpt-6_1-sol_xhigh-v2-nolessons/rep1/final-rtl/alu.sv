// rtl/alu.sv
//
// RV32IM combinational ALU. Hardware multiplier and divider are SystemVerilog
// `*` on signed/unsigned types. Standalone instances optionally retain
// combinational division; the core disables it and uses div_unit instead.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu #(
  // Standalone arithmetic tests retain their combinational interface.
  // EX sets this to zero, so / and % are eliminated at elaboration.
  parameter bit COMBINATIONAL_DIV = 1'b1,
  // The core isolates multiplication from the live MEM load bypass.
  // Default instances keep the original standalone a/b interface.
  parameter bit SEPARATE_MUL_OPERANDS = 1'b0
) (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [31:0] mul_a,
  input  logic [31:0] mul_b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] div_result;
  logic [31:0] product_a, product_b;

  assign product_a = SEPARATE_MUL_OPERANDS ? mul_a : a;
  assign product_b = SEPARATE_MUL_OPERANDS ? mul_b : b;

  generate
    if (COMBINATIONAL_DIV) begin : g_div
      always_comb begin
        div_result = 32'd0;
        case (op)
`ifdef RISCV_FORMAL_ALTOPS
          ALU_DIV:  div_result = (a - b) ^ 32'h7f8529ec;
          ALU_DIVU: div_result = (a - b) ^ 32'h10e8fd70;
          ALU_REM:  div_result = (a - b) ^ 32'h8da68fa5;
          ALU_REMU: div_result = (a - b) ^ 32'h3138d0e1;
`else
          ALU_DIV: begin
            if (b == 32'd0) div_result = 32'hffffffff;
            else if (a == 32'h80000000 && b == 32'hffffffff)
              div_result = 32'h80000000;
            else div_result = $unsigned($signed(a) / $signed(b));
          end
          ALU_DIVU: div_result = (b == 32'd0) ? 32'hffffffff : (a / b);
          ALU_REM: begin
            if (b == 32'd0) div_result = a;
            else if (a == 32'h80000000 && b == 32'hffffffff)
              div_result = 32'd0;
            else div_result = $unsigned($signed(a) % $signed(b));
          end
          ALU_REMU: div_result = (b == 32'd0) ? a : (a % b);
`endif
          default: div_result = 32'd0;
        endcase
      end
    end else begin : g_no_div
      assign div_result = 32'd0;
    end
  endgenerate

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

    mul_ss = $signed({{32{product_a[31]}}, product_a}) * $signed({{32{product_b[31]}}, product_b});
    mul_uu = {32'b0, product_a} * {32'b0, product_b};
    mul_su = $signed({{32{product_a[31]}}, product_a}) * $signed({32'b0, product_b});

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
      ALU_MUL:    out = (product_a + product_b) ^ 32'h5876063e;
      ALU_MULH:   out = (product_a + product_b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (product_a + product_b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (product_a - product_b) ^ 32'hecfbe137;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
`endif
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_result;
      default:  out = 32'b0;
    endcase
  end

endmodule
