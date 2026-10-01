// rtl/alu.sv
//
// RV32I combinational ALU (EX stage) plus the RV32M multiplier unit
// (MEM stage).
//
// The ALU is a set of parallel units combined by registered group selects
// decoded in ID (no op-code case in EX):
//   add   : one shared 33-bit adder a + (b ^ {32{sub}}) + cin. Bit 32 of the
//           sign- (or, for SLTU, zero-) extended subtract is SLT / SLTU.
//   slt   : sum[32] folded into bit 0 (sub = 1)
//   sll   : a_sll << shamt_l
//   sr    : a_sr >> shamt_r (arith = sign fill)
//   logic : one LUT5 per bit on the 2-bit op lop (00 AND, 01 OR, 10 XOR,
//           11 b pass-through for LUI, whose b = imm)
//   early : register-sourced groups pre-merged in EX (link, div result,
//           AUIPC pc + imm)
// The result leaves in two halves, each latched by its own EX/MEM field
// and OR-ed back together by the consumers (EX forward mux, MEM merge):
//   add_out : the gated adder sum (plus SLT / SLTU in bit 0), so the carry
//             chain reaches the EX/MEM flop with at most one LUT
//   oth_out : sll | sr | logic | early, one LUT4 over kept group nets
// Each shifter has its group select folded into its last (shamt[4]) mux
// stage. With no select set (and early = 0) both halves are 0.
//
// a_sll / a_sr / shamt_l / shamt_r carry the same values as a / b[4:0], and
// cin the same value as sub; ex_stage drives them from their own copies of
// the operand muxes (and ID/EX select / sub flops) so the shifters and the
// carry-in do not load the adder's operand / sub nets.
//
// MUL* are NOT computed by `alu`: the 33x33 DSP product spans EX->MEM
// (mul_unit below). DIV / DIVU / REM / REMU run on the iterative divider
// (rtl/divider.sv); ex_stage passes its result in through `early`.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB) for ALU ops.
module alu (
  input  logic        sel_add,
  input  logic        sel_slt,
  input  logic        sel_sll,
  input  logic        sel_sr,
  input  logic        sel_logic,
  input  logic [1:0]  lop,      // 00 AND, 01 OR, 10 XOR, 11 pass b
  input  logic        sub,      // SUB / SLT / SLTU: b XOR
  input  logic        cin,      // SUB / SLT / SLTU: carry-in (= sub)
  input  logic        arith,    // SRA
  input  logic        uns,      // SLTU
  input  logic [31:0] a,        // adder / logic operand A
  input  logic [31:0] a_sll,    // SLL operand A (= a)
  input  logic [31:0] a_sr,     // SRL / SRA operand A (= a)
  input  logic [31:0] b,
  input  logic [4:0]  shamt_l,  // SLL shift amount (= b[4:0])
  input  logic [4:0]  shamt_r,  // SRL / SRA shift amount (= b[4:0])
  input  logic [31:0] early,    // pre-merged register-sourced result groups
  output logic [31:0] add_out,  // adder group (ADD / SUB / SLT / SLTU)
  output logic [31:0] oth_out   // every other group
);

  logic [32:0] sum;
  logic [31:0] sl1;      // a_sll << shamt_l[1:0]
  logic [31:0] sl2;      // sl1  << shamt_l[3:2]*4
  logic [31:0] sll_g   /* synthesis syn_keep=1 */;
  logic        fill;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr1_w;
  logic [32:0] sr2_w;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] sr2;
  logic [31:0] sr_g    /* synthesis syn_keep=1 */;
  logic [31:0] logic_r;
  logic [31:0] logic_g /* synthesis syn_keep=1 */;

  always_comb begin
    sum     = {a[31] & ~uns, a}
            + ({b[31] & ~uns, b} ^ {33{sub}})
            + {32'b0, cin};

    // SLL: two 4:1 stages, then the shamt[4] stage with the group select.
    sl1     = a_sll << shamt_l[1:0];
    sl2     = sl1  << {shamt_l[3:2], 2'b00};
    sll_g   = {32{sel_sll}} & (shamt_l[4] ? {sl2[15:0], 16'b0} : sl2);

    // SRL / SRA: same shape, fill = sign bit for SRA.
    fill    = arith & a_sr[31];
    sr1_w   = $signed({fill, a_sr})       >>> shamt_r[1:0];
    sr2_w   = $signed({fill, sr1_w[31:0]}) >>> {shamt_r[3:2], 2'b00};
    sr2     = sr2_w[31:0];
    sr_g    = {32{sel_sr}} & (shamt_r[4] ? {{16{fill}}, sr2[31:16]} : sr2);

    // Logic group: one LUT5 per bit (sel_logic, lop, a, b).
    logic_r = lop[1] ? (lop[0] ? b : (a ^ b))
                     : (lop[0] ? (a | b) : (a & b));
    logic_g = {32{sel_logic}} & logic_r;

    add_out    = {32{sel_add}} & sum[31:0];
    add_out[0] = add_out[0] | (sel_slt & sum[32]);
    oth_out    = sll_g | sr_g | logic_g | early;
  end

endmodule

// mul_unit
//
// RV32M multiplier. One 33x33 signed product: each operand is extended to
// 33 bits by a bit latched in EX/MEM (ax = mul_a_sgn & rs1[31] for
// MULH/MULHSU, bx = mul_b_sgn & rs2[31] for MULH, else 0), so every DSP
// input is a flop and there is no op decode in front of the array. The
// one-hot registered selects pick the low (MUL) or high (MULH/MULHU/MULHSU)
// half; with neither set the output is 0. Instantiated in mem_stage on the
// EX/MEM-latched rs1/rs2 values; the result is OR-merged into MEM/WB.result.
//
// Under RISCV_FORMAL_ALTOPS the hardware operations are substituted for
// tractable algebraic stand-ins so bitwuzla can solve the BMC inside the
// 20-step depth budget. The same substitution must appear in the
// riscv-formal spec (insn_*.v). The stand-ins still decode `op`
// (EX/MEM.ctrl.alu_op); the real branch ignores it. The Verilator/cocotb/
// cosim builds leave ALTOPS undefined and run the real arithmetic.
//
// Latency:        combinational (0 cycles) — sits between EX/MEM and MEM/WB.
// RVFI fields:    feeds rd_wdata for MUL/MULH/MULHU/MULHSU (via MEM/WB).
/* verilator lint_off DECLFILENAME */
module mul_unit (
/* verilator lint_on DECLFILENAME */
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [4:0]  op,       // ALTOPS stand-ins only
  input  logic        ax,       // operand a extension bit (33rd bit)
  input  logic        bx,       // operand b extension bit (33rd bit)
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic        sel_lo,   // MUL
  input  logic        sel_hi,   // MULH / MULHU / MULHSU
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

`ifdef RISCV_FORMAL_ALTOPS
  always_comb begin
    case (op)
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      default:    out = 32'b0;
    endcase
    if (!(sel_lo || sel_hi)) out = 32'b0;
  end
`else
  // [65:64] are never used.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [65:0] prod;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    prod = $signed({ax, a}) * $signed({bx, b});
    out  = ({32{sel_lo}} & prod[31:0]) | ({32{sel_hi}} & prod[63:32]);
  end
`endif

endmodule
