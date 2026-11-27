// rtl/alu.sv
//
// RV32IM combinational ALU. The hardware multiplier is SystemVerilog `*`
// on signed/unsigned types (DSP blocks). DIV/DIVU/REM/REMU are NOT
// computed here: the sequential divider in rtl/div_unit.sv produces a
// registered result that enters this module's result mux as `div_result`
// (ex_stage stalls the pipeline until it is valid).
//
// Operands: a/b are the FINAL ALU operands of the non-M arms (selected
// in ID: pc or rs1, 4 or imm or rs2). ma/mb are the raw register operands
// (rs1/rs2) and feed ONLY the multiplier (and its RISCV_FORMAL_ALTOPS
// stand-ins), so the DSP inputs come straight from flops and a/b never
// fan out into the multiplier.
//
// Latency:        combinational (0 cycles); DIV/REM arms just select the
//                 already-registered divider result.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB). The dmem address is NOT
//                 produced here (dedicated AGU adder in ex_stage).
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [31:0] ma,          // multiplier operand: rs1
  input  logic [31:0] mb,          // multiplier operand: rs2
  input  logic [31:0] div_result,  // registered div_unit result
  output logic [31:0] out
);

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

  // Result mux, split by arrival time. The shifters are the deepest
  // logic in EX, so their results are OR-ed in at the very end instead
  // of going through the wide op-select mux:
  //   base_r : add / sub / logic / compare / LUI / divider  (0 otherwise)
  //   mul_r  : the four MUL arms                            (0 otherwise)
  //   out    = base_r | mul_r | (is_sll & sll_r) | (is_sr & sr_r)
  // Exactly one of the four terms is non-zero for any legal op.
  logic               is_sll;
  logic               is_sr;
  logic               sr_fill;
  logic        [31:0] sll_r;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [32:0] sr_x;    // {fill, a} >>> shamt: SRL (fill 0) / SRA;
                               // bit 32 is only the sign source
  /* verilator lint_on UNUSEDSIGNAL */
  logic        [31:0] base_r;
  logic        [31:0] mul_r;

  always_comb begin
    shamt = b[4:0];

    mul_ss = $signed({{32{ma[31]}}, ma}) * $signed({{32{mb[31]}}, mb});
    mul_uu = {32'b0, ma} * {32'b0, mb};
    mul_su = $signed({{32{ma[31]}}, ma}) * $signed({32'b0, mb});

    // ── Shifters ────────────────────────────────────────────────────────
    is_sll  = (op == ALU_SLL);
    is_sr   = (op == ALU_SRL) || (op == ALU_SRA);
    sr_fill = (op == ALU_SRA) && a[31];
    sll_r   = a << shamt;
    sr_x    = $signed({sr_fill, a}) >>> shamt;

    // ── Everything that is neither a shift nor a multiply ───────────────
    case (op)
      ALU_ADD:    base_r = a + b;
      ALU_SUB:    base_r = a - b;
      ALU_AND:    base_r = a & b;
      ALU_OR:     base_r = a | b;
      ALU_XOR:    base_r = a ^ b;
      ALU_SLT:    base_r = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   base_r = {31'b0, a < b};
      ALU_LUI:    base_r = b;
      // DIV/DIVU/REM/REMU: the registered result of the sequential
      // divider (rtl/div_unit.sv), in both the real and the ALTOPS
      // build.
      ALU_DIV,
      ALU_DIVU,
      ALU_REM,
      ALU_REMU:   base_r = div_result;
      default:    base_r = 32'b0;   // shifts, MUL*, unused encodings
    endcase

    // ── M-extension multiplies (operands ma/mb = rs1/rs2, both builds) ──
    // Under RISCV_FORMAL_ALTOPS the hardware operations are substituted
    // for tractable algebraic stand-ins so bitwuzla can solve the BMC
    // inside the 20-step depth budget. The same substitution must appear
    // in the riscv-formal spec (insn_*.v). The Verilator/cocotb/cosim
    // builds leave ALTOPS undefined and run the real arithmetic.
    case (op)
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    mul_r = (ma + mb) ^ 32'h5876063e;
      ALU_MULH:   mul_r = (ma + mb) ^ 32'hf6583fb7;
      ALU_MULHU:  mul_r = (ma + mb) ^ 32'h949ce5e8;
      ALU_MULHSU: mul_r = (ma - mb) ^ 32'hecfbe137;
`else
      ALU_MUL:    mul_r = mul_uu[31:0];
      ALU_MULH:   mul_r = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  mul_r = mul_uu[63:32];
      ALU_MULHSU: mul_r = $unsigned(mul_su[63:32]);
`endif
      default:    mul_r = 32'b0;
    endcase

    out = base_r | mul_r
        | ({32{is_sll}} & sll_r)
        | ({32{is_sr}}  & $unsigned(sr_x[31:0]));
  end

endmodule
