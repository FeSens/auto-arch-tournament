// rtl/alu.sv
//
// RV32IM combinational ALU. Hardware multiplier and divider are SystemVerilog
// `*` and `/` on signed/unsigned types — Verilator and Yosys both support
// these and emit reasonable structural hardware.
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
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;

  // One unsigned product serves every MUL-family operation.  Reinterpreting
  // an RV32 operand as signed changes its 64-bit product by operand*2^32, so
  // only the high half needs correction (modulo 2^32):
  //   signed(a)*unsigned(b) high = unsigned_product_high - (a[31] ? b : 0)
  //   signed(a)*signed(b)   high = the above - (b[31] ? a : 0)
  // The low half is identical for all signedness combinations.
  logic [63:0] mul_product;
  logic [31:0] mul_high_su;
  logic [31:0] mul_high_ss;

  always_comb begin
    shamt = b[4:0];

    mul_product = {32'b0, a} * {32'b0, b};
    mul_high_su = mul_product[63:32] - (a[31] ? b : 32'b0);
    mul_high_ss = mul_high_su         - (b[31] ? a : 32'b0);

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
      ALU_MUL:    out = mul_product[31:0];
      ALU_MULH:   out = mul_high_ss;
      ALU_MULHU:  out = mul_product[63:32];
      ALU_MULHSU: out = mul_high_su;
      ALU_DIV: begin
        if (b == 32'b0)
          out = 32'hFFFFFFFF;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'h80000000;
        else
          out = $unsigned($signed(a) / $signed(b));
      end
      ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a / b);
      ALU_REM: begin
        if (b == 32'b0)
          out = a;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          out = 32'b0;
        else
          out = $unsigned($signed(a) % $signed(b));
      end
      ALU_REMU: out = (b == 32'b0) ? a : (a % b);
`endif
      default:  out = 32'b0;
    endcase
  end

endmodule
