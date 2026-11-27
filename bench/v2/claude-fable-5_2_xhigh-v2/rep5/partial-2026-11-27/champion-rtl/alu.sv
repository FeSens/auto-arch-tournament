// rtl/alu.sv
//
// RV32I combinational ALU with a FLAT result select.
//
// The result class is pre-decoded in ID into registered one-hot selects,
// so the output is a single AND-OR of the unit results instead of a
// binary-op case mux:
//
//   out = sel_add & (a +/- b)          one shared 33-bit add/sub adder
//       | sel_slt & lt                 (SLT/SLTU = bit 32 of the subtract)
//       | logic(a, b, logic_op)        (00 selects nothing)
//       | sel_shl & (a << sh) | sel_shr & (a >> / >>> sh)
//       | other                        pre-gated link / muldiv value
//
// At most one class is selected; with none selected out = other.
// The RV32M operations live in rtl/muldiv.sv; EX feeds their result in
// through `other`.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB).
module alu (
  input  logic        sel_add,     // result = a + b / a - b
  input  logic        sub,         // adder subtracts (SUB, SLT, SLTU)
  input  logic        sel_slt,     // result = {31'b0, a < b}  (needs sub = 1)
  input  logic        slt_signed,  // signed compare for sel_slt
  input  logic [1:0]  logic_op,    // 00 none, 01 AND, 10 OR, 11 XOR
  input  logic        sel_shl,     // result = a << b[4:0]
  input  logic        sel_shr,     // result = a >> b[4:0] (fill = sh_arith & a[31])
  input  logic        sh_arith,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [31:0] other,       // OR-ed in (must be 0 when a class is selected)
  output logic [31:0] out
);

  // Shared add/sub. Bit 32 extends each operand with its sign (signed
  // compare) or 0 (unsigned compare), so bit 32 of the difference is a < b.
  logic [32:0] ax;
  logic [32:0] bx;
  logic [32:0] sum;
  always_comb begin
    ax  = {slt_signed & a[31], a};
    bx  = {slt_signed & b[31], b};
    sum = sub ? (ax - bx) : (ax + bx);
  end

  logic [31:0] lgc;
  always_comb begin
    case (logic_op)
      2'b01:   lgc = a & b;
      2'b10:   lgc = a | b;
      2'b11:   lgc = a ^ b;
      default: lgc = 32'b0;
    endcase
  end

  // Barrel shifters as two 4:1 stages + one 2:1 stage (3 mux levels).
  logic [4:0]  shamt;
  logic        fill;
  logic [31:0] l1, l2, shl;
  logic [31:0] r1, r2, shr;
  always_comb begin
    shamt = b[4:0];
    fill  = sh_arith & a[31];

    case (shamt[1:0])
      2'd0:    l1 = a;
      2'd1:    l1 = {a[30:0], 1'b0};
      2'd2:    l1 = {a[29:0], 2'b0};
      default: l1 = {a[28:0], 3'b0};
    endcase
    case (shamt[3:2])
      2'd0:    l2 = l1;
      2'd1:    l2 = {l1[27:0], 4'b0};
      2'd2:    l2 = {l1[23:0], 8'b0};
      default: l2 = {l1[19:0], 12'b0};
    endcase
    shl = shamt[4] ? {l2[15:0], 16'b0} : l2;

    case (shamt[1:0])
      2'd0:    r1 = a;
      2'd1:    r1 = {fill, a[31:1]};
      2'd2:    r1 = {{2{fill}}, a[31:2]};
      default: r1 = {{3{fill}}, a[31:3]};
    endcase
    case (shamt[3:2])
      2'd0:    r2 = r1;
      2'd1:    r2 = {{4{fill}},  r1[31:4]};
      2'd2:    r2 = {{8{fill}},  r1[31:8]};
      default: r2 = {{12{fill}}, r1[31:12]};
    endcase
    shr = shamt[4] ? {{16{fill}}, r2[31:16]} : r2;
  end

  always_comb begin
    out = ({32{sel_add}} & sum[31:0])
        | ({32{sel_shl}} & shl)
        | ({32{sel_shr}} & shr)
        | lgc
        | other;
    out[0] = out[0] | (sel_slt & sum[32]);
  end

endmodule
