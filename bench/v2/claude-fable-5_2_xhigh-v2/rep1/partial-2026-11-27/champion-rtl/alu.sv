// rtl/alu.sv
//
// RV32I combinational ALU (ADD/SUB/logic/SLT/SLTU/shifts/LUI).
//
// The M-extension is NOT here any more: MUL*/DIV*/REM* are computed by the
// multi-cycle unit in rtl/muldiv.sv (which also carries the
// RISCV_FORMAL_ALTOPS stand-ins). For the M alu_op codes this module
// returns 0; ex_stage muxes the muldiv result in instead.
//
// Three outputs:
//   add_out   : a + b, or a - b when op == ALU_SUB. Valid for every op; it
//               is the late-arriving carry chain, so ex_stage selects it in
//               the LAST mux level (pre-decoded select bit from ID).
//   other_out : the non-adder result (logic, shifts, SLT/SLTU, LUI);
//               0 for ADD/SUB and the M op codes.
//   out       : the classic single result (add_out for ADD/SUB, other_out
//               otherwise). Kept for the unit tests; the pipeline does not
//               use it.
//
// Structure of other_out (kept shallow on purpose — it is the deepest EX
// cone once the adder is selected late):
//   - SRL and SRA share ONE right barrel shifter (33-bit arithmetic shift
//     with the fill bit = SRA & a[31]); SLL has its own.
//   - SLT/SLTU share one unsigned magnitude compare (signed result fixed
//     up from the sign bits).
//   - The result is a flat AND-OR over one-hot op decodes (op comes from
//     flops, so the decodes settle in parallel with the operand muxes);
//     the shifters are gated at their inputs and just OR in.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB) and mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] add_out,
  output logic [31:0] other_out,
  output logic [31:0] out
);

  logic [4:0]  shamt;
  logic        sub;

  logic        is_and, is_or, is_xor, is_lui;
  logic        is_slt, is_sltu, is_sll, is_sr;

  logic        ltu;
  logic        lt;
  logic        sr_fill;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sr_ext;     // bit 32 is the fill copy; never read
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] sr_in;
  logic [31:0] sl_in;
  logic [31:0] sl_out;
  logic [31:0] early_out;

  always_comb begin
    shamt = b[4:0];
    sub   = (op == ALU_SUB);

    add_out = sub ? (a - b) : (a + b);

    is_and  = (op == ALU_AND);
    is_or   = (op == ALU_OR);
    is_xor  = (op == ALU_XOR);
    is_lui  = (op == ALU_LUI);
    is_slt  = (op == ALU_SLT);
    is_sltu = (op == ALU_SLTU);
    is_sll  = (op == ALU_SLL);
    is_sr   = (op == ALU_SRL) || (op == ALU_SRA);

    // One unsigned compare; signed "less than" differs only when the sign
    // bits differ (then a is smaller iff a is the negative one).
    ltu = (a < b);
    lt  = (a[31] != b[31]) ? a[31] : ltu;

    // Shared right shifter: logical when the fill bit is 0, arithmetic
    // when it copies a[31].
    // Each shifter's INPUT is gated by its op decode (absorbed into the
    // first shift stage), so an unselected shifter outputs 0 and the
    // result below is a plain OR instead of a select behind the barrels.
    sr_fill = (op == ALU_SRA) && a[31];
    sr_in   = is_sr  ? a : 32'b0;
    sl_in   = is_sll ? a : 32'b0;
    sr_ext  = $unsigned($signed({sr_fill, sr_in}) >>> shamt);
    sl_out  = sl_in << shamt;

    // Shallow terms first (bitwise logic, LUI pass-through, set-less-than)…
    early_out = ({32{is_and}} & (a & b))
              | ({32{is_or}}  & (a | b))
              | ({32{is_xor}} & (a ^ b))
              | ({32{is_lui}} & b)
              | {31'b0, (is_slt & lt) | (is_sltu & ltu)};

    // …the barrel shifters join last.
    other_out = sl_out | sr_ext[31:0] | early_out;

    out = (op == ALU_ADD || op == ALU_SUB) ? add_out : other_out;
  end

endmodule
