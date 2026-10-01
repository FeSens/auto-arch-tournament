// rtl/alu.sv
//
// RV32IM combinational ALU (everything except divide), in three modules:
//
//   alu_dec  : alu_op -> one-hot result selects (alu_sel_t). id_stage
//              runs it in ID and registers the selects in ID/EX.
//   alu_core : the EX datapath, driven by the registered selects.
//              base_out is an AND-OR of one shared add/sub carry chain
//              (SLT / SLTU come from its sign / carry-out), a logic LUT
//              (2-bit code, 00 = off) and the masked shifters, so each
//              result bit is about one LUT after the adder SUM.
//              mul_out is the MUL* product from a single signed 33x33
//              `*` on the DSP blocks; ex_stage registers it apart from
//              base_out (EX/MEM.xres) and MEM selects it.
//   alu      : alu_dec + alu_core behind the old op/a/b interface (LUI
//              zeroes a, as ID does); used by the unit test.
//
// DIV / DIVU / REM / REMU are handled by the sequential rtl/divider.sv;
// every select is 0 for those ops, so base_out is 0.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB).
/* verilator lint_off DECLFILENAME */
module alu_dec (
  input  logic [4:0] op,
  output alu_sel_t   sel
);

  always_comb begin
    sel = '0;
    case (op)
      ALU_ADD, ALU_LUI: sel.sel_arith = 1'b1;
      ALU_SUB:    begin sel.sel_arith = 1'b1; sel.sub = 1'b1; end
      ALU_AND:    sel.logic_op = 2'b01;
      ALU_OR:     sel.logic_op = 2'b10;
      ALU_XOR:    sel.logic_op = 2'b11;
      ALU_SLT:    begin sel.sel_slt  = 1'b1; sel.sub = 1'b1; end
      ALU_SLTU:   begin sel.sel_sltu = 1'b1; sel.sub = 1'b1; end
      ALU_SLL:    sel.sel_sll = 1'b1;
      ALU_SRL:    sel.sel_sr  = 1'b1;
      ALU_SRA:    begin sel.sel_sr = 1'b1; sel.sra = 1'b1; end
      ALU_MUL:    ;
      ALU_MULH:   begin sel.mul_sa = 1'b1; sel.mul_sb = 1'b1; sel.mul_hi = 1'b1; end
      ALU_MULHSU: begin sel.mul_sa = 1'b1; sel.mul_hi = 1'b1; end
      ALU_MULHU:  sel.mul_hi = 1'b1;
      default:    ;
    endcase
  end

endmodule

module alu_core (
  input  alu_sel_t    sel,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] base_out,
  output logic [31:0] mul_out
);

  logic [4:0]  shamt;
  logic [32:0] sum;       // {carry-out, a + (b ^ sub) + sub}
  logic        slt, sltu;
  logic [31:0] logic_m;
  logic [31:0] sll_m;
  logic [31:0] sr_m;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr_full;   // bit 32 is the arithmetic fill, dropped
  /* verilator lint_on UNUSEDSIGNAL */

  // One signed 33x33 product serves every MUL* op. Each operand is
  // sign-extended only when the op treats it as signed. prod[65:64]
  // and the extension bits are dead and are dropped by synthesis.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];

    sum  = {1'b0, a} + {1'b0, b ^ {32{sel.sub}}} + {32'b0, sel.sub};
    // a - b: signs differ -> a is the smaller iff negative; else the
    // difference's sign (no overflow). Unsigned borrow = no carry-out.
    slt  = (a[31] ^ b[31]) ? a[31] : sum[31];
    sltu = !sum[32];

    case (sel.logic_op)
      2'b01:   logic_m = a & b;
      2'b10:   logic_m = a | b;
      2'b11:   logic_m = a ^ b;
      default: logic_m = 32'b0;
    endcase

    sll_m   = {32{sel.sel_sll}} & (a << shamt);
    sr_full = $unsigned($signed({sel.sra & a[31], a}) >>> shamt);
    sr_m    = {32{sel.sel_sr}} & sr_full[31:0];

    base_out = ({32{sel.sel_arith}} & sum[31:0]) | logic_m | sll_m | sr_m
             | {31'b0, (sel.sel_slt & slt) | (sel.sel_sltu & sltu)};

    prod = $signed({sel.mul_sa & a[31], a}) * $signed({sel.mul_sb & b[31], b});

    // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations
    // are substituted for tractable algebraic stand-ins so bitwuzla
    // can solve the BMC inside the 20-step depth budget. The same
    // substitution must appear in the riscv-formal spec (insn_*.v).
    // The Verilator/cocotb/cosim builds leave ALTOPS undefined and
    // run the real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
    if (!sel.mul_hi)                    mul_out = (a + b) ^ 32'h5876063e; // MUL
    else if (sel.mul_sa && sel.mul_sb)  mul_out = (a + b) ^ 32'hf6583fb7; // MULH
    else if (!sel.mul_sa)               mul_out = (a + b) ^ 32'h949ce5e8; // MULHU
    else                                mul_out = (a - b) ^ 32'hecfbe137; // MULHSU
`else
    mul_out = sel.mul_hi ? prod[63:32] : prod[31:0];
`endif
  end

endmodule

/* verilator lint_on DECLFILENAME */
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out,
  output logic        mul_sel,   // op is MUL / MULH / MULHU / MULHSU
  output logic [31:0] mul_out,   // MUL* result (valid when mul_sel)
  output logic [31:0] base_out   // every non-MUL op (0 for MUL* / DIV*)
);

  alu_sel_t sel;
  alu_dec u_dec (.op(op), .sel(sel));

  alu_core u_core (
    .sel      (sel),
    .a        ((op == ALU_LUI) ? 32'b0 : a),
    .b        (b),
    .base_out (base_out),
    .mul_out  (mul_out)
  );

  assign mul_sel = (op == ALU_MUL)  || (op == ALU_MULH) ||
                   (op == ALU_MULHU) || (op == ALU_MULHSU);
  assign out     = mul_sel ? mul_out : base_out;

endmodule
