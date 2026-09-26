// rtl/alu.sv
//
// RV32IM combinational ALU: RV32I ops plus the four MUL variants, split
// in two so the opcode decode is off the EX critical path:
//
//   alu_predecode  op (ALU_*) -> alu_ctl_t. Runs in ID; the result is
//                  registered in ID/EX.
//   alu_core       (ctl, a, b) -> out. Runs in EX from the registered
//                  controls: one shared 33-bit add/sub (ADD, SUB, and
//                  SLT/SLTU from its sign / carry), one 33-bit arithmetic
//                  right shift (SRL/SRA), one signed 33x33 product
//                  (MUL/MULH/MULHU/MULHSU), and a one-hot AND-OR result
//                  merge instead of an opcode-indexed mux.
//   alu            the original (op, a, b) -> out view, chaining the two.
//                  Used by test/test_alu.py; the core instantiates the
//                  halves separately (id_stage / ex_stage).
//
// The hardware multiplier is SystemVerilog `*` on signed types, which
// both Verilator and Yosys support and turn into reasonable structural
// hardware.
//
// DIV / DIVU / REM / REMU are NOT computed here: they run in the
// multi-cycle div_unit beside the ALU (see div_unit.sv), which keeps the
// combinational divider off the ID/EX -> ALU -> EX/MEM critical path.
// They predecode to all-zero controls, so the ALU output is 0.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.

/* verilator lint_off DECLFILENAME */
module alu_predecode (
  input  logic [4:0] op,
  output alu_ctl_t   ctl
);

  always_comb begin
    ctl = '0;
    case (op)
      ALU_ADD:    ctl.sel_sum = 1'b1;
      ALU_SUB:    begin ctl.sel_sum  = 1'b1; ctl.sub = 1'b1; end
      ALU_AND:    ctl.sel_and = 1'b1;
      ALU_OR:     ctl.sel_or  = 1'b1;
      ALU_XOR:    ctl.sel_xor = 1'b1;
      ALU_SLT:    begin ctl.sel_slt  = 1'b1; ctl.sub = 1'b1; end
      ALU_SLTU:   begin ctl.sel_sltu = 1'b1; ctl.sub = 1'b1; end
      ALU_SLL:    ctl.sel_sll = 1'b1;
      ALU_SRL:    ctl.sel_sr  = 1'b1;
      ALU_SRA:    begin ctl.sel_sr   = 1'b1; ctl.sra = 1'b1; end
      ALU_LUI:    ctl.sel_b   = 1'b1;
      ALU_MUL:    ctl.sel_mul_lo = 1'b1;
      ALU_MULH:   begin
                    ctl.sel_mul_hi = 1'b1;
                    ctl.mul_a_sgn  = 1'b1;
                    ctl.mul_b_sgn  = 1'b1;
                  end
      ALU_MULHU:  ctl.sel_mul_hi = 1'b1;
      ALU_MULHSU: begin ctl.sel_mul_hi = 1'b1; ctl.mul_a_sgn = 1'b1; end
      // ALU_DIV / ALU_DIVU / ALU_REM / ALU_REMU run in div_unit (EX
      // stage injects its registered result); no select, output 0.
      default:    ;
    endcase
  end

endmodule

module alu_core (
  input  alu_ctl_t    ctl,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic [32:0] sum;      // {carry, a + b} or {carry, a - b} (sub)
  logic        lt_s;
  logic        lt_u;
  logic [31:0] sll;
  // sr_ext[32] is the fill bit, shifted out of the 32-bit result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr_ext;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] mul_lo;
  logic [31:0] mul_hi;

  always_comb begin
    // a - b = a + ~b + 1; carry out = (a >= b) unsigned.
    sum  = {1'b0, a} + {1'b0, b ^ {32{ctl.sub}}} + {32'b0, ctl.sub};
    // Signs differ: a < b iff a is negative. Same sign: the difference
    // cannot overflow, so its sign bit is the answer.
    lt_s = (a[31] ^ b[31]) ? a[31] : sum[31];
    lt_u = !sum[32];
    sll  = a << b[4:0];
    sr_ext = $unsigned($signed({ctl.sra & a[31], a}) >>> b[4:0]);
  end

  // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations are
  // substituted for tractable algebraic stand-ins so bitwuzla can solve
  // the BMC inside the 20-step depth budget. The same substitution must
  // appear in the riscv-formal spec (insn_*.v). The Verilator/cocotb/
  // cosim builds leave ALTOPS undefined and run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    mul_lo = (a + b) ^ 32'h5876063e;                         // MUL
    mul_hi = ctl.mul_b_sgn ? ((a + b) ^ 32'hf6583fb7)        // MULH
           : ctl.mul_a_sgn ? ((a - b) ^ 32'hecfbe137)        // MULHSU
           :                 ((a + b) ^ 32'h949ce5e8);       // MULHU
  end
`else
  // One signed product of the sign- or zero-extended 33-bit operands
  // covers all four variants. prod[65:64] only repeat the sign.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    prod   = $signed({{34{ctl.mul_a_sgn & a[31]}}, a})
           * $signed({{34{ctl.mul_b_sgn & b[31]}}, b});
    mul_lo = prod[31:0];
    mul_hi = prod[63:32];
  end
`endif

  always_comb begin
    out = ({32{ctl.sel_sum}}    & sum[31:0])
        | ({32{ctl.sel_and}}    & (a & b))
        | ({32{ctl.sel_or}}     & (a | b))
        | ({32{ctl.sel_xor}}    & (a ^ b))
        | ({32{ctl.sel_sll}}    & sll)
        | ({32{ctl.sel_sr}}     & sr_ext[31:0])
        | ({32{ctl.sel_b}}      & b)
        | ({32{ctl.sel_mul_lo}} & mul_lo)
        | ({32{ctl.sel_mul_hi}} & mul_hi)
        | {31'b0, (ctl.sel_slt & lt_s) | (ctl.sel_sltu & lt_u)};
  end

endmodule
/* verilator lint_on DECLFILENAME */

module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  alu_ctl_t ctl;

  alu_predecode u_pd   (.op(op), .ctl(ctl));
  alu_core      u_core (.ctl(ctl), .a(a), .b(b), .out(out));

endmodule
