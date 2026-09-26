// rtl/alu.sv
//
// RV32IM combinational ALU for the one-cycle EX-stage datapath. Multiply
// remains here; DIV/DIVU/REM/REMU are handled by div_unit.sv so the FPGA
// divider/remainder hardware is not part of every ALU-result path.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic        [31:0] simple_out;
  logic        [31:0] m_out;

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

    // M-extension multiply. Under RISCV_FORMAL_ALTOPS the hardware
    // operations are substituted for tractable algebraic stand-ins so
    // bitwuzla can solve the BMC inside the 20-step depth budget. The
    // divide/remainder ALTOPS substitutions live in div_unit.sv.
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    m_out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   m_out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHSU: m_out = (a - b) ^ 32'hecfbe137;
      ALU_MULHU:  m_out = (a + b) ^ 32'h949ce5e8;
`else
      ALU_MUL:    m_out = mul_uu[31:0];
      ALU_MULH:   m_out = $unsigned(mul_ss[63:32]);
      ALU_MULHSU: m_out = $unsigned(mul_su[63:32]);
      ALU_MULHU:  m_out = mul_uu[63:32];
`endif
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU:   m_out = 32'b0;
      default:    m_out = 32'b0;
    endcase

    out = op[4] ? m_out : simple_out;
  end

endmodule
