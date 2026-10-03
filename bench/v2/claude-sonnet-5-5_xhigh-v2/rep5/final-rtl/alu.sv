// rtl/alu.sv
//
// RV32I single-cycle combinational ALU datapaths. The M-extension (multiply /
// divide / remainder) lives in rtl/mdu.sv: it is a multi-cycle unit whose
// result EX muxes into EX/MEM, so none of the deep multiplier / divider
// logic sits in the ALU's combinational cone.
//
// alu_cand exposes the candidate results separately (adder, SLT bit, shifter)
// so EX can AND-OR them with the one-hot select flops decoded in ID. The
// sub-op controls (sub / slt_u / sh_left / sh_arith) are also plain flops.
//   - ONE adder serves ADD, SUB, SLT and SLTU: b is conditionally inverted
//     with carry-in = sub; the 33rd sum bit is the unsigned "a >= b" flag.
//   - ONE right shifter serves SLL / SRL / SRA: SLL bit-reverses the input
//     and the output, SRA fills with a[31].
//
// alu is the op-encoded wrapper (5-bit alu_op -> result) used by the unit
// test; the core does not instantiate it. For ALU_MUL..ALU_REMU it outputs 0.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), mem_addr.
module alu (
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic [31:0] add_res;
  logic        slt_res;
  logic [31:0] shift_res;

  alu_cand u_cand (
    .a         (a),
    .b         (b),
    .sub       (op == ALU_SUB || op == ALU_SLT || op == ALU_SLTU),
    .slt_u     (op == ALU_SLTU),
    .sh_left   (op == ALU_SLL),
    .sh_arith  (op == ALU_SRA),
    .add_res   (add_res),
    .slt_res   (slt_res),
    .shift_res (shift_res)
  );

  always_comb begin
    case (op)
      ALU_ADD, ALU_SUB:             out = add_res;
      ALU_AND:                      out = a & b;
      ALU_OR:                       out = a | b;
      ALU_XOR:                      out = a ^ b;
      ALU_SLT, ALU_SLTU:            out = {31'b0, slt_res};
      ALU_SLL, ALU_SRL, ALU_SRA:    out = shift_res;
      ALU_LUI:                      out = b;
      default:                      out = 32'b0;
    endcase
  end

endmodule


/* verilator lint_off DECLFILENAME */
module alu_cand (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        sub,       // adder computes a - b
  input  logic        slt_u,     // SLTU (else signed SLT)
  input  logic        sh_left,   // SLL
  input  logic        sh_arith,  // SRA
  output logic [31:0] add_res,
  output logic        slt_res,
  output logic [31:0] shift_res
);

  // ── Shared adder / comparator ──────────────────────────────────────────
  logic [32:0] sum;
  logic        ltu;
  always_comb begin
    sum     = {1'b0, a} + {1'b0, b ^ {32{sub}}} + {32'b0, sub};
    add_res = sum[31:0];
    // sub = 1: sum[32] = carry-out = (a >= b) unsigned.
    ltu     = !sum[32];
    // Signed: differing signs decide by a's sign (= ltu ^ a31 ^ b31).
    slt_res = slt_u ? ltu : (ltu ^ a[31] ^ b[31]);
  end

  // ── Shared shifter ─────────────────────────────────────────────────────
  logic [31:0] sh_in;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] sh_r;   // [32] (shifted-out sign copy) unused
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] sh_r_lo;
  logic [4:0]  shamt;

  function automatic logic [31:0] rev32(input logic [31:0] x);
    for (int i = 0; i < 32; i++) rev32[i] = x[31 - i];
  endfunction

  always_comb begin
    shamt   = b[4:0];
    sh_in   = sh_left ? rev32(a) : a;
    sh_r    = $unsigned($signed({sh_arith & a[31], sh_in}) >>> shamt);
    sh_r_lo = sh_r[31:0];
    shift_res = sh_left ? rev32(sh_r_lo) : sh_r_lo;
  end

endmodule
/* verilator lint_on DECLFILENAME */
