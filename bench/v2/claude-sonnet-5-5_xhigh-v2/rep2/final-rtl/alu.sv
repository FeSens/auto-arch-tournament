// rtl/alu.sv
//
// RV32IM ALU. The single-cycle base-ISA ops are always built. The M
// extension has two personalities, selected by HAS_MULDIV:
//   HAS_MULDIV=1 (default): combinational reference — hardware multiplier
//     and divider are SystemVerilog `*` and `/` on signed/unsigned types.
//     This is the golden model that test_alu.py exercises.
//   HAS_MULDIV=0: the M-op arms read 0 and no multiplier/divider is
//     synthesized. ex_stage uses this and runs MUL/DIV/REM through the
//     multi-cycle muldiv unit instead.
// Under RISCV_FORMAL_ALTOPS the algebraic stand-ins are built regardless of
// HAS_MULDIV (ex_stage forces its is_muldiv off in that mode), so the formal
// view of the core is unchanged.
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
  parameter bit HAS_MULDIV = 1
) (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

  // Combinational M-extension result (real arithmetic). Constant 0 when
  // HAS_MULDIV=0, so the arithmetic below is not elaborated.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] m_out;
  /* verilator lint_on UNUSEDSIGNAL */

  if (HAS_MULDIV) begin : g_md
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
      mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
      mul_uu = {32'b0, a} * {32'b0, b};
      mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

      case (op)
        ALU_MUL:    m_out = mul_uu[31:0];
        ALU_MULH:   m_out = $unsigned(mul_ss[63:32]);
        ALU_MULHU:  m_out = mul_uu[63:32];
        ALU_MULHSU: m_out = $unsigned(mul_su[63:32]);
        ALU_DIV: begin
          if (b == 32'b0)
            m_out = 32'hFFFFFFFF;
          else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
            m_out = 32'h80000000;
          else
            m_out = $unsigned($signed(a) / $signed(b));
        end
        ALU_DIVU: m_out = (b == 32'b0) ? 32'hFFFFFFFF : (a / b);
        ALU_REM: begin
          if (b == 32'b0)
            m_out = a;
          else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
            m_out = 32'b0;
          else
            m_out = $unsigned($signed(a) % $signed(b));
        end
        ALU_REMU: m_out = (b == 32'b0) ? a : (a % b);
        default:  m_out = 32'b0;
      endcase
    end
  end else begin : g_nomd
    assign m_out = 32'b0;
  end

  always_comb begin
    shamt = b[4:0];

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
      // run the real arithmetic (here when HAS_MULDIV=1, in muldiv.sv
      // otherwise).
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
      ALU_MUL, ALU_MULH, ALU_MULHU, ALU_MULHSU,
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
                  out = m_out;
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
