// rtl/alu.sv
//
// RV32I single-cycle combinational ALU: add/sub/logic/shift/compare.
//
// The ALU does NOT merge its result classes: it outputs four unmuxed
// legs that EX registers straight into EX/MEM (sum/dif/sh/lg). The
// consumer picks the leg with the producer's result class (id_ex_t.k,
// registered one cycle early), folded into its own one-hot operand
// AND-OR, and mem_stage merges OR(class & leg) for write-back.
//   sum : a + b   (ADD/ADDI, LUI = 0 + imm, AUIPC, JAL/JALR link pc + 4)
//   dif : a - b   (SUB)
//   sh  : r_sll ? a << b : a >> b (SRL/SRA share one right shifter whose
//         fill bit is r_sra & a[31])
//   lg  : SLT/SLTU/XOR/OR/AND AND-OR of ID-registered one-hot selects
// `out` is the merged view (unit tests only; pruned in the core).
//
// The M-extension (MUL/MULH/MULHU/MULHSU/DIV/DIVU/REM/REMU) is NOT
// executed here: those ops run in the multi-cycle rtl/muldiv.sv unit
// while the pipeline stalls in EX (ex_stage puts the muldiv result on
// the lg leg for is_muldiv instructions).
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM legs, MEM/WB.wb_data).
module alu (
  input  logic        r_add,
  input  logic        r_sub,
  input  logic        r_slt,
  input  logic        r_sltu,
  input  logic        r_xor,
  input  logic        r_or,
  input  logic        r_and,
  input  logic        r_sll,
  input  logic        r_shr,
  input  logic        r_sra,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] sum,
  output logic [31:0] dif,
  output logic [31:0] sh,
  output logic [31:0] lg,
  output logic [31:0] out
);

  logic [4:0]  shamt;
  logic        lt;
  logic        ltu;
  logic [31:0] shl;
  // shr_x[32] is the fill bit shifted along; only [31:0] is the result.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] shr_x;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    shamt = b[4:0];
    sum   = a + b;
    dif   = a - b;
    lt    = $signed(a) < $signed(b);
    ltu   = a < b;
    shl   = a << shamt;
    shr_x = $unsigned($signed({r_sra & a[31], a}) >>> shamt);
    sh    = r_sll ? shl : shr_x[31:0];

    lg  = {31'b0, (r_slt & lt) | (r_sltu & ltu)}
        | ({32{r_xor}} & (a ^ b))
        | ({32{r_or}}  & (a | b))
        | ({32{r_and}} & (a & b));

    out = ({32{r_add}} & sum)
        | ({32{r_sub}} & dif)
        | ({32{r_sll | r_shr}} & sh)
        | lg;
  end

endmodule
