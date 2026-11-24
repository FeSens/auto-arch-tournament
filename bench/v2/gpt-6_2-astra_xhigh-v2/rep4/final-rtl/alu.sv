// rtl/alu.sv
//
// RV32IM ALU with a seven-round, magnitude-partitioned restoring divider.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic [4:0]  op,
  input  logic [10:0] result_sel,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        div_start,   // one issue pulse while idle
  input  logic        div_accept,  // downstream can capture a completed result
  output logic        div_busy,
  output logic        div_last,    // result can transfer on the upcoming edge
  output logic        div_done,
  output logic [31:0] div_result,
  output logic [31:0] out
);

  // Round seven writes the result on the EX/MEM transfer edge. Enter
  // the held state only when downstream cannot accept that transfer.
  logic [3:0] round_q;
  assign div_busy = round_q != 4'd0;
  assign div_last = round_q == 4'd7;
  assign div_done = round_q == 4'd8;

  always_ff @(posedge clock) begin
    if (reset)                               round_q <= 4'd0;
    else if (div_start)                      round_q <= 4'd1;
    else if ((div_last || div_done) && div_accept) round_q <= 4'd0;
    else if (div_busy && !div_done)          round_q <= round_q + 4'd1;
  end

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  always_ff @(posedge clock) begin
    if (div_start) begin
      case (op)
        ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
        default:  alt_result_q <= (a - b) ^ 32'h3138d0e1; // REMU
      endcase
    end
    if (div_last) div_result <= alt_result_q;
  end
`else
  logic [31:0] dividend_abs, divisor_abs, divisor_q, zero_result_q;
  logic [19:0] triple_small_divisor_q;
  logic [4:0]  lane_q;
  logic        want_rem_q, negate_q, zero_q;
  logic        signed_op, want_rem;
  logic        negative_a, negative_b;
  assign signed_op  = op == ALU_DIV || op == ALU_REM;
  assign want_rem   = op == ALU_REM || op == ALU_REMU;
  assign negative_a = signed_op && a[31];
  assign negative_b = signed_op && b[31];
  assign dividend_abs = negative_a ? -a : a;
  assign divisor_abs  = negative_b ? -b : b;

  always_ff @(posedge clock) begin
    if (div_start) begin
      divisor_q     <= divisor_abs;
      triple_small_divisor_q <= {1'b0, divisor_abs[17:0], 1'b0} + {2'b0, divisor_abs[17:0]};
      lane_q[0]     <= divisor_abs[31:4]  == 0;
      lane_q[1]     <= divisor_abs[31:11] == 0 && divisor_abs[10:4]  != 0;
      lane_q[2]     <= divisor_abs[31:18] == 0 && divisor_abs[17:11] != 0;
      lane_q[3]     <= divisor_abs[31:25] == 0 && divisor_abs[24:18] != 0;
      lane_q[4]     <= divisor_abs[31:25] != 0;
      want_rem_q    <= want_rem;
      negate_q      <= want_rem ? negative_a : negative_a ^ negative_b;
      zero_q        <= b == 0;
      zero_result_q <= want_rem ? a : 32'hffff_ffff;
    end
  end

  // Each lane consumes seven groups of dividend bits. The omitted high
  // prefix is smaller than the lane's minimum divisor and seeds R.
  logic [31:0] selected_quotient [0:4], selected_remainder [0:4];
  for (genvar lane = 0; lane < 5; lane++) begin : g_lane
    localparam int DIGITS = 5 - lane;
    localparam int Q_BITS = 7 * DIGITS;
    localparam int R_BITS = 4 + 7 * lane;
    localparam int PAIRS = lane < 3 ? DIGITS / 2 : 0;
    localparam int SINGLES = DIGITS - 2 * PAIRS;

    logic [Q_BITS-1:0] quotient_q, quotient_next;
    logic [R_BITS-1:0] remainder_q, remainder_next;
    logic [R_BITS-1:0] initial_remainder;
    logic [R_BITS-1:0] stage_remainder [0:SINGLES+PAIRS];
    logic [DIGITS-1:0] digits;
    if (lane == 0) begin : g_zero_seed
      assign initial_remainder = '0;
    end else begin : g_prefix_seed
      assign initial_remainder = R_BITS'(dividend_abs[31:Q_BITS]);
    end

    // Consume leading single bits before the trailing radix-4 pairs.
    // The two wide lanes consume all their bits with binary restores.
    assign stage_remainder[0] = remainder_q;
    for (genvar i = 0; i < SINGLES; i++) begin : g_binary
      wire [R_BITS:0] shifted = {stage_remainder[i], quotient_q[Q_BITS-1-i]};
      logic [R_BITS-1:0] difference;
      logic borrow, unused_high;
      assign {borrow, unused_high, difference} = {1'b0, shifted} - {2'b0, divisor_q[R_BITS-1:0]};
      assign stage_remainder[i+1] = borrow ? shifted[R_BITS-1:0] : difference;
      assign digits[DIGITS-1-i] = !borrow;
    end
    for (genvar pair = 0; pair < PAIRS; pair++) begin : g_radix4
      localparam int STAGE = SINGLES + pair;
      localparam int OFFSET = SINGLES + 2 * pair;
      wire [R_BITS+1:0] shifted = {stage_remainder[STAGE], quotient_q[Q_BITS-1-OFFSET -: 2]};
      logic [R_BITS-1:0] diff1, diff2, diff3;
      logic borrow1;
      logic [1:0] unused_high2, unused_high3;
      logic lt1, lt2, lt3;
      // D fits in R_BITS. Its two high comparison bits can be checked
      // in parallel with the low difference.
      assign {borrow1, diff1} = {1'b0, shifted[R_BITS-1:0]} - {1'b0, divisor_q[R_BITS-1:0]};
      assign lt1 = shifted[R_BITS+1:R_BITS] == 0 && borrow1;
      assign {lt2, unused_high2, diff2[R_BITS-1:1]} =
          {1'b0, shifted[R_BITS+1:1]} - {2'b0, divisor_q[R_BITS-1:0]};
      assign diff2[0] = shifted[0];
      assign {lt3, unused_high3, diff3} = {1'b0, shifted} - {1'b0, triple_small_divisor_q[R_BITS+1:0]};
      assign stage_remainder[STAGE+1] = lt2 ? (lt1 ? shifted[R_BITS-1:0] : diff1) :
                                             (lt3 ? diff2 : diff3);
      assign digits[DIGITS-1-OFFSET -: 2] = {!lt2, !lt3 || (lt2 && !lt1)};
    end
    assign remainder_next = stage_remainder[SINGLES+PAIRS];
    assign quotient_next = {quotient_q[Q_BITS-DIGITS-1:0], digits};

    always_ff @(posedge clock) begin
      if (div_start) begin
        remainder_q <= initial_remainder;
        quotient_q  <= Q_BITS'(dividend_abs);
      end else if (div_busy && !div_done) begin
        remainder_q <= remainder_next;
        quotient_q  <= quotient_next;
      end
    end

    // Round seven clocks each lane's final state on the EX/MEM edge.
    // MEM selects the completed lane while these registers are held.
    assign selected_quotient[lane]  = 32'(quotient_q)  & {32{lane_q[lane]}};
    assign selected_remainder[lane] = 32'(remainder_q) & {32{lane_q[lane]}};
  end

  logic [31:0] quotient, remainder, magnitude;
  assign quotient  = selected_quotient[0]  | selected_quotient[1]  | selected_quotient[2] |
                     selected_quotient[3]  | selected_quotient[4];
  assign remainder = selected_remainder[0] | selected_remainder[1] | selected_remainder[2] |
                     selected_remainder[3] | selected_remainder[4];

  // MEM reads the held state even after div_accept. MEM/WB samples this
  // result on or before the edge that initializes the next divide.
  assign magnitude  = want_rem_q ? remainder : quotient;
  assign div_result = zero_q ? zero_result_q : (negate_q ? -magnitude : magnitude);
`endif

  logic [4:0] shamt;
  assign shamt = b[4:0];
  assign out = ({32{result_sel[ALU_ADD[3:0]]}}  & (a + b)) |
               ({32{result_sel[ALU_SUB[3:0]]}}  & (a - b)) |
               ({32{result_sel[ALU_AND[3:0]]}}  & (a & b)) |
               ({32{result_sel[ALU_OR[3:0]]}}   & (a | b)) |
               ({32{result_sel[ALU_XOR[3:0]]}}  & (a ^ b)) |
               ({32{result_sel[ALU_SLT[3:0]]}}  & {31'b0, $signed(a) < $signed(b)}) |
               ({32{result_sel[ALU_SLTU[3:0]]}} & {31'b0, a < b}) |
               ({32{result_sel[ALU_SLL[3:0]]}}  & (a << shamt)) |
               ({32{result_sel[ALU_SRL[3:0]]}}  & (a >> shamt)) |
               ({32{result_sel[ALU_SRA[3:0]]}}  & $unsigned($signed(a) >>> shamt)) |
               ({32{result_sel[ALU_LUI[3:0]]}}  & b);

endmodule

/* verilator lint_off DECLFILENAME */
module multiplier (
  // The formal model selects its formula by opcode. The DSP takes the
  // extension bits directly from EX.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [4:0]  op,
  input  logic        lhs_ext,
  input  logic        rhs_ext,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [63:0] product
);
/* verilator lint_on DECLFILENAME */
`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result;
  always_comb begin
    case (op)
      ALU_MUL:    alt_result = (a + b) ^ 32'h5876063e;
      ALU_MULH:   alt_result = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_result = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_result = (a - b) ^ 32'hecfbe137;
      default:    alt_result = 32'b0;
    endcase
  end
  assign product = {2{alt_result}};
`else
  assign product = $signed({lhs_ext, a}) * $signed({rhs_ext, b});
`endif
endmodule
