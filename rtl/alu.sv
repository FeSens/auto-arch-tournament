// rtl/alu.sv
//
// RV32IM ALU. All non-divide operations are combinational (0 cycles).
// DIV/DIVU/REM/REMU run on a multi-cycle iterative divider (rtl/divu.sv)
// in the synthesis / cocotb / cosim build, exposed via a start/busy/done
// handshake to the EX stage. Under RISCV_FORMAL_ALTOPS the M-extension
// operations (including div/rem) revert to combinational XOR-of-add/sub
// stand-ins so the per-iteration formal gate keeps its 20-step BMC
// budget — see riscv-formal docs §7.6.
//
// RV32IM division semantics (handled at the ALU boundary, NOT inside
// divu):
//   DIV  by 0       -> -1   (all ones)
//   DIVU by 0       -> 0xFFFFFFFF
//   DIV  INT_MIN/-1 -> INT_MIN  (no trap, defined overflow)
//   REM  by 0       -> dividend
//   REMU by 0       -> dividend
//   REM  INT_MIN/-1 -> 0
// Edge cases short-circuit the FSM: alu.div_busy stays 0 and alu.div_done
// pulses with start_div, so EX/MEM captures the result the same cycle
// the divide enters EX.
//
// Latency:
//   - All non-div ops: combinational (0 cycles).
//   - DIV/DIVU/REM/REMU (real operands, non-ALTOPS): 33 cycles.
//   - DIV/DIVU/REM/REMU (edge case, non-ALTOPS): combinational.
//   - All ops (ALTOPS build): combinational.
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB); the div_busy/div_done
//                 handshake gates EX/MEM register capture in ex_stage,
//                 keeping rvfi_order monotonic across the multi-cycle
//                 divide.
module alu (
  input  logic        clock,
  input  logic        reset,
  input  logic        start_div,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        div_busy,
  output logic        div_done,
  output logic [31:0] out
);

  logic [4:0] shamt;

  // 64-bit products. mul_ss/mul_su low halves are unused (only MULH /
  // MULHSU read the high half). Yosys dead-code-eliminates the unused
  // bits.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */

`ifdef RISCV_FORMAL_ALTOPS
  // Combinational div/rem via XOR-of-add/sub stand-ins. clock / reset /
  // start_div are unused in this build — the dummy assign keeps any
  // future ALTOPS lint clean.
  /* verilator lint_off UNUSEDSIGNAL */
  wire _altops_unused = clock | reset | start_div;
  /* verilator lint_on UNUSEDSIGNAL */
  assign div_busy = 1'b0;
  // div_done = 1 forever so ex_stage's div_pipeline_stall stays 0 in
  // the formal build (combinational behavior matches the prior ALU).
  assign div_done = 1'b1;
`else
  // ── Real iterative divider + sign correction ─────────────────────────
  logic        is_div_op;
  logic        is_signed_div;
  logic        is_rem_op;
  logic        edge_case;
  logic [31:0] edge_result;
  logic [31:0] op_a_abs;
  logic [31:0] op_b_abs;
  logic        sign_q;
  logic        sign_r;
  logic        divu_start;
  logic [31:0] divu_quot;
  logic [31:0] divu_rem;
  logic        divu_busy;
  logic        divu_done;
  logic [31:0] div_q_signed;
  logic [31:0] div_r_signed;
  logic [31:0] div_alu_out;

  always_comb begin
    is_div_op     = (op == ALU_DIV)  || (op == ALU_DIVU)
                 || (op == ALU_REM)  || (op == ALU_REMU);
    is_signed_div = (op == ALU_DIV)  || (op == ALU_REM);
    is_rem_op     = (op == ALU_REM)  || (op == ALU_REMU);

    edge_case   = 1'b0;
    edge_result = 32'b0;
    if (is_div_op) begin
      if (b == 32'b0) begin
        edge_case   = 1'b1;
        edge_result = is_rem_op ? a : 32'hFFFFFFFF;
      end else if (is_signed_div
                   && a == 32'h80000000 && b == 32'hFFFFFFFF) begin
        edge_case   = 1'b1;
        edge_result = is_rem_op ? 32'h00000000 : 32'h80000000;
      end
    end

    op_a_abs = (is_signed_div && a[31]) ? (~a + 32'd1) : a;
    op_b_abs = (is_signed_div && b[31]) ? (~b + 32'd1) : b;

    // Quotient is negated when exactly one operand is negative; remainder
    // takes the sign of the dividend (RV32M sign-fixup rules).
    sign_q = is_signed_div && (a[31] ^ b[31]);
    sign_r = is_signed_div && a[31];

    // Edge cases bypass the FSM. divu_start only fires for real divides
    // — a div-by-zero or INT_MIN/-1 finishes combinationally below.
    divu_start = start_div && is_div_op && !edge_case;
  end

  divu u_divu (
    .clock     (clock),
    .reset     (reset),
    .start     (divu_start),
    .dividend  (op_a_abs),
    .divisor   (op_b_abs),
    .quotient  (divu_quot),
    .remainder (divu_rem),
    .busy      (divu_busy),
    .done      (divu_done)
  );

  always_comb begin
    div_q_signed = sign_q ? (~divu_quot + 32'd1) : divu_quot;
    div_r_signed = sign_r ? (~divu_rem  + 32'd1) : divu_rem;

    if (edge_case)      div_alu_out = edge_result;
    else if (is_rem_op) div_alu_out = div_r_signed;
    else                div_alu_out = div_q_signed;
  end

  // External handshake.
  //   div_busy: high from the cycle start_div is asserted (for real
  //             divides) through the DONE state. 0 for edge cases.
  //   div_done: pulses 1 on the DONE state (real divides) or in the
  //             same cycle start_div is asserted (edge cases) — either
  //             way it tells ex_stage "result is on `out` now".
  assign div_busy = !edge_case && divu_busy;
  assign div_done = edge_case ? (start_div && is_div_op) : divu_done;
`endif

  // ── Combinational ALU result mux ────────────────────────────────────
  always_comb begin
    shamt = b[4:0];

    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});

    case (op)
      ALU_ADD:    out = a + b;
      ALU_SUB:    out = a - b;
      ALU_AND:    out = a & b;
      ALU_OR:     out = a | b;
      ALU_XOR:    out = a ^ b;
      ALU_SLT:    out = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU:   out = {31'b0, a < b};
      ALU_SLL:    out = a << shamt;
      ALU_SRL:    out = a >> shamt;
      ALU_SRA:    out = $unsigned($signed(a) >>> shamt);
      ALU_LUI:    out = b;
`ifdef RISCV_FORMAL_ALTOPS
      ALU_MUL:    out = (a + b) ^ 32'h5876063e;
      ALU_MULH:   out = (a + b) ^ 32'hf6583fb7;
      ALU_MULHU:  out = (a + b) ^ 32'h949ce5e8;
      ALU_MULHSU: out = (a - b) ^ 32'hecfbe137;
      ALU_DIV:    out = (a - b) ^ 32'h7f8529ec;
      ALU_DIVU:   out = (a - b) ^ 32'h10e8fd70;
      ALU_REM:    out = (a - b) ^ 32'h8da68fa5;
      ALU_REMU:   out = (a - b) ^ 32'h3138d0e1;
`else
      ALU_MUL:    out = mul_uu[31:0];
      ALU_MULH:   out = $unsigned(mul_ss[63:32]);
      ALU_MULHU:  out = mul_uu[63:32];
      ALU_MULHSU: out = $unsigned(mul_su[63:32]);
      ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU: out = div_alu_out;
`endif
      default:    out = 32'b0;
    endcase
  end

endmodule
