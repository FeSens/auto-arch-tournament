// rtl/alu.sv
//
// RV32IM combinational ALU. The hardware multiplier is the SystemVerilog
// `*` on a single shared signed 33x33 product (operands extended with
// a[31]&signed_a / b[31]&signed_b, so MUL/MULH/MULHU/MULHSU all read the
// same multiplier).
//
// Division: with HW_DIV = 1 (default, used by test_alu.py) the `/` and
// `%` operators build a fully combinational divider with the RV32IM
// semantics below. The core instantiates this module with HW_DIV = 0 and
// computes DIV/DIVU/REM/REMU in the sequential divider (divider.sv)
// instead, because a combinational 32-bit divide is by far the longest
// path in the design.
//
// RV32IM division semantics (overridden from straight `signed /`):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
//
// Control decode: with PREDEC = 0 (default, used by test_alu.py) the result
// class and the multiplier operand signedness are decoded from the 5-bit `op`
// here. With PREDEC = 1 (the core, outside ALTOPS) `op` is ignored and the
// caller supplies them as registered one-hot flags (msa_i / msb_i / sel_*), so
// the DSP sign-extension bit is `a[31] & flop` and the fast result is a flat
// AND-OR over the sel_* flops instead of a 5-bit case. HW_DIV must be 0 with
// PREDEC = 1 (the divider ops read 0 here either way).
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu #(
  // Unused under RISCV_FORMAL_ALTOPS (the XOR stand-ins replace `/` `%`).
  /* verilator lint_off UNUSEDPARAM */
  parameter bit HW_DIV = 1,
  parameter bit PREDEC = 0
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic [4:0]  op,
  // Predecoded controls (PREDEC = 1 only; ignored otherwise).
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        msa_i,      // a is signed for the product (MULH, MULHSU)
  input  logic        msb_i,      // b is signed for the product (MULH)
  input  logic        sel_mul_lo,
  input  logic        sel_mul_hi,
  input  logic        sel_add,
  input  logic        sel_sub,
  input  logic        sel_and,
  input  logic        sel_or,
  input  logic        sel_xor,
  input  logic        sel_slt,
  input  logic        sel_sltu,
  input  logic        sel_sll,
  input  logic        sel_srl,
  input  logic        sel_sra,
  input  logic        sel_lui,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] a,
  input  logic [31:0] b,
  // out      : full result (what test_alu.py checks).
  // fast_out : every op except the multiplier legs (the multiplier ops
  //            read 0 here). The product arrives ~6 ns after the
  //            adder/logic/shift legs, so ex_stage selects mul_lo/mul_hi
  //            at the very last mux level instead of burying the DSP
  //            output behind this op case.
  // mul_lo / mul_hi : product halves (0 under RISCV_FORMAL_ALTOPS).
  output logic [31:0] out,
  output logic [31:0] fast_out,
  output logic [31:0] mul_lo,
  output logic [31:0] mul_hi
);

  logic        [4:0]  shamt;
  logic        [31:0] case_out;   // op-decoded fast result (PREDEC = 0)
  logic        [31:0] flat_out;   // flag-selected fast result (PREDEC = 1)

  // One signed 33x33 product, computed once and selected per op.
  // MUL reads the low half (identical for any operand signedness); the
  // MULH* ops read the high half. Verilator's UNUSEDSIGNAL is silenced
  // locally — the unused bits are dead-code-eliminated by synthesis.
  logic               mul_sa;   // treat a as signed
  logic               mul_sb;   // treat b as signed
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] mul_p;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    if (PREDEC) begin
      mul_sa = msa_i;
      mul_sb = msb_i;
    end else begin
      mul_sa = (op == ALU_MULH) || (op == ALU_MULHSU);
      mul_sb = (op == ALU_MULH);
    end
    mul_a  = $signed({a[31] & mul_sa, a});
    mul_b  = $signed({b[31] & mul_sb, b});
    mul_p  = mul_a * mul_b;

`ifdef RISCV_FORMAL_ALTOPS
    mul_lo = 32'b0;
    mul_hi = 32'b0;
`else
    mul_lo = mul_p[31:0];
    mul_hi = mul_p[63:32];
`endif

    case (op)
      ALU_ADD:    case_out = a + b;
      ALU_SUB:    case_out = a - b;
      ALU_AND:    case_out = a & b;
      ALU_OR:     case_out = a | b;
      ALU_XOR:    case_out = a ^ b;
      ALU_SLT:    case_out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   case_out = {31'b0, a < b};
      ALU_SLL:    case_out = a << shamt;
      ALU_SRL:    case_out = a >> shamt;
      ALU_SRA:    case_out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    case_out = b;

      // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
      // are substituted for tractable algebraic stand-ins so bitwuzla
      // can solve the BMC inside the 20-step depth budget. The same
      // substitution must appear in the riscv-formal spec (insn_*.v).
      // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
      // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    case_out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   case_out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  case_out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: case_out = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    case_out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   case_out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    case_out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   case_out = (a - b) ^ 32'h3138d0e1;
`else
      ALU_DIV: begin
        if (!HW_DIV)
          case_out = 32'b0;
        else if (b == 32'b0)
          case_out = 32'hFFFFFFFF;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          case_out = 32'h80000000;
        else
          case_out = $unsigned($signed(a) / $signed(b));
      end
      ALU_DIVU: begin
        if (!HW_DIV)
          case_out = 32'b0;
        else
          case_out = (b == 32'b0) ? 32'hFFFFFFFF : (a / b);
      end
      ALU_REM: begin
        if (!HW_DIV)
          case_out = 32'b0;
        else if (b == 32'b0)
          case_out = a;
        else if (a == 32'h80000000 && b == 32'hFFFFFFFF)
          case_out = 32'b0;
        else
          case_out = $unsigned($signed(a) % $signed(b));
      end
      ALU_REMU: begin
        if (!HW_DIV)
          case_out = 32'b0;
        else
          case_out = (b == 32'b0) ? a : (a % b);
      end
`endif
      default:  case_out = 32'b0;
    endcase

    // Flat AND-OR over the one-hot result-class flags (no 5-bit case).
    flat_out = ({32{sel_add }} & (a + b))
             | ({32{sel_sub }} & (a - b))
             | ({32{sel_and }} & (a & b))
             | ({32{sel_or  }} & (a | b))
             | ({32{sel_xor }} & (a ^ b))
             | {31'b0, (sel_slt  && ($signed(a) < $signed(b)))}
             | {31'b0, (sel_sltu && (a < b))}
             | ({32{sel_sll }} & (a << shamt))
             | ({32{sel_srl }} & (a >> shamt))
             | ({32{sel_sra }} & $unsigned($signed(a) >>> shamt))
             | ({32{sel_lui }} & b);

    fast_out = PREDEC ? flat_out : case_out;

    // Full result: multiplier legs last, as in ex_stage.
    if (PREDEC) begin
      out = fast_out | ({32{sel_mul_lo}} & mul_lo) | ({32{sel_mul_hi}} & mul_hi);
    end else begin
      case (op)
`ifndef RISCV_FORMAL_ALTOPS
        ALU_MUL:                          out = mul_lo;
        ALU_MULH, ALU_MULHU, ALU_MULHSU:  out = mul_hi;
`endif
        default:                          out = fast_out;
      endcase
    end
  end

endmodule
