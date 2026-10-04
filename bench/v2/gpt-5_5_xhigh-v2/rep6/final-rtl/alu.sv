// rtl/alu.sv
//
// RV32IM combinational ALU. RV32I operations and MUL/MULH variants stay on
// the single-cycle execute path. DIV/DIVU/REM/REMU are handled by the
// iterative divider in ex_stage.sv for synthesis builds, keeping "/" and "%"
// off the ALU timing path.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] simple_out,
  output logic [31:0] mul_out,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic        [31:0] div_alt_out;

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
    shamt      = b[4:0];
    simple_out = 32'b0;
    case (op)
      ALU_ADD:  simple_out = a + b;
      ALU_SUB:  simple_out = a - b;
      ALU_AND:  simple_out = a & b;
      ALU_OR:   simple_out = a | b;
      ALU_XOR:  simple_out = a ^ b;
      ALU_SLT:  simple_out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU: simple_out = {31'b0, a < b};
      ALU_SLL:  simple_out = a << shamt;
      ALU_SRL:  simple_out = a >> shamt;
      ALU_SRA:  simple_out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:  simple_out = b;
      default:  simple_out = 32'b0;
    endcase
  end

  // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations are
  // substituted for tractable algebraic stand-ins so bitwuzla can solve the
  // BMC inside the 20-step depth budget. The Verilator/cocotb/cosim builds
  // leave ALTOPS undefined and run the real arithmetic.
  always_comb begin
    mul_ss  = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu  = {32'b0, a} * {32'b0, b};
    mul_su  = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
    mul_out = 32'b0;
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    mul_out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   mul_out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_out = (a - b) ^ 32'hecfbe137;
`else
      ALU_MUL:    mul_out = mul_uu[31:0];
      ALU_MULH:   mul_out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  mul_out = mul_uu[63:32];
      ALU_MULHSU: mul_out = $unsigned(mul_su[63:32]);
`endif
      default:    mul_out = 32'b0;
    endcase
  end

  always_comb begin
    div_alt_out = 32'b0;
`ifdef RISCV_FORMAL_ALTOPS
    case (op)
      ALU_DIV:  div_alt_out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU: div_alt_out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:  div_alt_out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU: div_alt_out = (a - b) ^ 32'h3138d0e1;
      default:  div_alt_out = 32'b0;
    endcase
`endif
  end

  // Legacy combined output for the standalone ALU tests. The core datapath
  // consumes simple_out/mul_out directly and gets DIV/REM from divider.sv.
  always_comb begin
    case (op)
      ALU_MUL,
      ALU_MULH,
      ALU_MULHU,
      ALU_MULHSU: out = mul_out;
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU:   out = div_alt_out;
      default:    out = simple_out;
    endcase
  end

endmodule
