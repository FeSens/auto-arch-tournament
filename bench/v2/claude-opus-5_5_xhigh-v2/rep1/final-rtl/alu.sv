// rtl/alu.sv
//
// RV32IM ALU pieces (everything except DIV/DIVU/REM/REMU, which run on the
// sequential rtl/divider.sv and are muxed in by ex_stage).
//
//   alu_dec    : alu_op -> one-hot lane selects. Used in ID (registered
//                into ID/EX) and by the `alu` test wrapper.
//   alu_lanes  : flat base ALU. Parallel lanes, each pre-gated by its own
//                select, merged by one AND-OR:
//                  add/sub : one adder, b inverted by `sub`
//                  logic   : per-bit LUT4 {a, b, lop}: 00 zero / AND / OR / XOR
//                  sll     : a << shamt
//                  sr      : SRL/SRA (arith fill bit)
//                  slt     : bit 0 only, from the shared subtract
//   multiplier : ONE 33x33 signed product for MUL/MULH/MULHSU/MULHU. The
//                caller passes the extension bits (sign- or zero-):
//                  a_ext = {sa & a[31], a}, sa = MULH | MULHSU
//                  b_ext = {sb & b[31], b}, sb = MULH
//                MUL takes p[31:0], the MULH* variants p[63:32]. ex_stage
//                registers the whole product into EX/MEM (DSP output reg);
//                MEM selects the half.
//   alu        : combinational reference wrapper over the three above
//                (op, a, b -> out). Kept for the unit tests only.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB).

/* verilator lint_off DECLFILENAME */

// ── Lane decode ─────────────────────────────────────────────────────────
module alu_dec (
  input  logic [4:0] op,
  output logic       sel_add,   // ADD/SUB and the SLT/SLTU subtract
  output logic       sub,       // invert b, carry-in 1
  output logic [1:0] lop,       // logic lane: 00 off, 01 AND, 10 OR, 11 XOR
  output logic       sel_sll,
  output logic       sel_sr,    // SRL/SRA
  output logic       sh_arith,  // SRA
  output logic       sel_slt,   // SLT/SLTU (bit 0)
  output logic       slt_u,     // SLTU
  output logic       mul_lo,    // MUL      (product [31:0])
  output logic       mul_hi,    // MULH*    (product [63:32])
  output logic       mul_sa,    // a is signed (MULH/MULHSU)
  output logic       mul_sb     // b is signed (MULH)
);

  always_comb begin
    sel_add  = (op == ALU_ADD) || (op == ALU_SUB);
    sub      = (op == ALU_SUB) || (op == ALU_SLT) || (op == ALU_SLTU);
    case (op)
      ALU_AND: lop = 2'b01;
      ALU_OR:  lop = 2'b10;
      ALU_XOR: lop = 2'b11;
      default: lop = 2'b00;
    endcase
    sel_sll  = (op == ALU_SLL);
    sel_sr   = (op == ALU_SRL) || (op == ALU_SRA);
    sh_arith = (op == ALU_SRA);
    sel_slt  = (op == ALU_SLT) || (op == ALU_SLTU);
    slt_u    = (op == ALU_SLTU);
    mul_sa   = (op == ALU_MULH) || (op == ALU_MULHSU);
    mul_sb   = (op == ALU_MULH);
`ifdef RISCV_FORMAL_ALTOPS
    // The stand-in value sits in product [31:0] for every M op.
    mul_lo   = (op == ALU_MUL)  || (op == ALU_MULH) ||
               (op == ALU_MULHU) || (op == ALU_MULHSU);
    mul_hi   = 1'b0;
`else
    mul_lo   = (op == ALU_MUL);
    mul_hi   = (op == ALU_MULH) || (op == ALU_MULHU) || (op == ALU_MULHSU);
`endif
  end

endmodule

// ── Flat base ALU ───────────────────────────────────────────────────────
module alu_lanes (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        sel_add,
  input  logic        sub,
  input  logic [1:0]  lop,
  input  logic        sel_sll,
  input  logic        sel_sr,
  input  logic        sh_arith,
  input  logic        sel_slt,
  input  logic        slt_u,
  output logic [31:0] out
);

  logic [31:0] sum;
  logic [31:0] logic_out;
  logic [31:0] sll_out;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr_out;        // [32] is the fill bit
  /* verilator lint_on UNUSEDSIGNAL */
  logic        lt;
  logic [4:0]  shamt;

  always_comb begin
    shamt = b[4:0];
    sum   = a + (b ^ {32{sub}}) + {31'b0, sub};

    for (int i = 0; i < 32; i++) begin
      case (lop)
        2'b01:   logic_out[i] = a[i] & b[i];
        2'b10:   logic_out[i] = a[i] | b[i];
        2'b11:   logic_out[i] = a[i] ^ b[i];
        default: logic_out[i] = 1'b0;
      endcase
    end

    sll_out = a << shamt;
    sr_out  = $unsigned($signed({sh_arith & a[31], a}) >>> shamt);

    // a < b from the shared subtract: same signs -> the difference's
    // sign; different signs -> a's sign (signed) or b's sign (unsigned).
    lt = (a[31] ^ b[31]) ? (slt_u ? b[31] : a[31]) : sum[31];

    out = ({32{sel_add}} & sum)
        | logic_out
        | ({32{sel_sll}} & sll_out)
        | ({32{sel_sr}}  & sr_out[31:0])
        | {31'b0, sel_slt & lt};
  end

endmodule

// ── Multiplier (DSP) ────────────────────────────────────────────────────
module multiplier (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [4:0]  op,       // ALTOPS stand-in select only
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        a_sx,     // extension bit of a
  input  logic        b_sx,     // extension bit of b
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [63:0] p
);

  // M-extension. Under RISCV_FORMAL_ALTOPS the hardware operations are
  // substituted for tractable algebraic stand-ins so bitwuzla can solve
  // the BMC inside the 20-step depth budget. The same substitution must
  // appear in the riscv-formal spec (insn_*.v). The stand-in lands in
  // p[31:0] (alu_dec selects the low half for every M op then). The
  // simulation (cocotb/cosim) builds leave ALTOPS undefined and run the
  // real arithmetic.
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt;
  always_comb begin
    case (op)
      ALU_MULH:   alt = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt = (a - b) ^ 32'hecfbe137;
      default:    alt = (a + b) ^ 32'h5876063e;  // ALU_MUL
    endcase
    p = {32'b0, alt};
  end
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_sx;
  assign unused_sx = a_sx ^ b_sx;
  /* verilator lint_on UNUSEDSIGNAL */
`else
  // p_full[65:64] are never read (the true product of two 33-bit
  // operands fits 64 bits for every op used here).
  logic signed [32:0] mul_a;
  logic signed [32:0] mul_b;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] p_full;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    mul_a  = $signed({a_sx, a});
    mul_b  = $signed({b_sx, b});
    p_full = mul_a * mul_b;
    p      = p_full[63:0];
  end
`endif

endmodule

// ── Reference wrapper (unit tests) ──────────────────────────────────────
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] base_out,   // non-M ops (LUI = b); 0 for M ops
  output logic [31:0] mul_out,    // hi/lo-selected product (M ops)
  output logic [63:0] mul_p,      // full product register input
  output logic [31:0] out
);

  logic       sel_add, sub, sel_sll, sel_sr, sh_arith, sel_slt, slt_u;
  logic [1:0] lop;
  logic       mul_lo, mul_hi, mul_sa, mul_sb;
  logic [31:0] lanes;

  alu_dec u_dec (
    .op       (op),
    .sel_add  (sel_add),
    .sub      (sub),
    .lop      (lop),
    .sel_sll  (sel_sll),
    .sel_sr   (sel_sr),
    .sh_arith (sh_arith),
    .sel_slt  (sel_slt),
    .slt_u    (slt_u),
    .mul_lo   (mul_lo),
    .mul_hi   (mul_hi),
    .mul_sa   (mul_sa),
    .mul_sb   (mul_sb)
  );

  alu_lanes u_lanes (
    .a        (a),
    .b        (b),
    .sel_add  (sel_add),
    .sub      (sub),
    .lop      (lop),
    .sel_sll  (sel_sll),
    .sel_sr   (sel_sr),
    .sh_arith (sh_arith),
    .sel_slt  (sel_slt),
    .slt_u    (slt_u),
    .out      (lanes)
  );

  multiplier u_mul (
    .op   (op),
    .a_sx (mul_sa & a[31]),
    .b_sx (mul_sb & b[31]),
    .a    (a),
    .b    (b),
    .p    (mul_p)
  );

  always_comb begin
    base_out = lanes | ({32{op == ALU_LUI}} & b);
    mul_out  = ({32{mul_lo}} & mul_p[31:0]) | ({32{mul_hi}} & mul_p[63:32]);
    out      = (mul_lo || mul_hi) ? mul_out : base_out;
  end

endmodule
