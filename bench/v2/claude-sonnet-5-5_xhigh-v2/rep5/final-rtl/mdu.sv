// rtl/mdu.sv
//
// Multi-cycle RV32M multiply/divide unit. Takes every deep arithmetic cone
// out of the single-cycle ALU so the EX-stage critical path is only
// forward-mux -> adder/shifter/branch-compare.
//
// Handshake (the EX stage owns the M-op while it sits in ID/EX):
//   start      : an M-op is present in EX (ID/EX.valid && alu_op is M-ext).
//                Held high by the pipeline until the op is accepted.
//   busy       : start && !res_valid  (EX must hold the op and insert an
//                EX/MEM bubble).  Depends only on flops + `start`.
//   res_valid  : result register holds the answer for the op in EX; the
//                pipeline moves the op on and the MDU clears res_valid on
//                that same edge (!stall).
//   stall      : EX/MEM is frozen (dmem stall). The MDU does not capture,
//                advance or clear while stall is high.
//
// Operand capture: in the first EX cycle (state IDLE, !res_valid, !stall)
// the *forwarded* operands a/b and the op are latched into a_q/b_q/op_q.
// Forwarding sources vanish in later cycles, so everything after cycle 0
// works from the latched copies only. a_q/b_q are the raw operands and
// are also what RVFI reports as rs1/rs2 rdata for the M-op.
//
// Multiply (op MUL/MULH/MULHSU/MULHU). The four 17x17 signed partial
// products (16-bit unsigned low half, 17-bit signed high half of 33-bit
// sign/zero-extended operands) are registered into free-running pp_* flops
// (held only by stall). In the first EX cycle (state IDLE) the DSPs read the
// ID/EX operand flops a_id / b_id directly (no forward mux in front of
// them); in every later cycle they read the captured a_q / b_q.
//   fast path (no EX/MEM forward into this op, fwd_hit = 0):
//     E0 : pp_* <= products(a_id, b_id)  (a_q/b_q/op_q captured too)
//     MUL   : res_valid is raised at the end of E0; in the release cycle E1
//             the result is the combinational low-word sum of the pp flops
//             (no result register): ll + ((lh + hl) << 16) mod 2^32.
//     MULH* : E1 mid = lh + hl, E2 result <= high word of the 64-bit sum,
//             E3 release.
//   slow path (fwd_hit = 1: operand is the result of the op right ahead,
//   only present on the EX/MEM forward leg in E0): E0 captures a_q/b_q only,
//   S_MUL1 runs the DSPs off a_q/b_q, then MUL releases (res_valid) and
//   MULH* continues with the mid / sum states as above.
// Divide (DIV/DIVU/REM/REMU): INIT (|a|,|b|), 32 restoring-divide
//   iterations (one quotient bit per cycle), FIN (re-apply signs, special
//   cases) = 34 cycles after capture.
//   DIV  by 0       -> all ones     REM  by 0 -> dividend
//   INT_MIN / -1    -> falls out of the unsigned-magnitude algorithm
//                      (|INT_MIN| / 1 = 0x80000000, signs cancel; rem 0).
//
// Under RISCV_FORMAL_ALTOPS the op still takes the same handshake (one
// capture cycle + one compute cycle) but the result is the algebraic
// stand-in used by riscv-formal's insn_*.v (must match the spec there).
//
// Latency:        1 (MUL), 3 (MULH*) busy cycles on the fast path, +1 when
//                 fwd_hit; 35 (DIV*/REM*); 2 under RISCV_FORMAL_ALTOPS.
// RVFI fields:    a_q / b_q feed rs1_rdata / rs2_rdata of the M-op;
//                 result feeds rd_wdata.
module mdu (
  input  logic        clock,
  input  logic        reset,
  input  logic        stall,      // freeze (dmem stall)
  input  logic        start,      // valid M-op in EX
  input  logic [4:0]  op,         // ALU_MUL .. ALU_REMU
  input  logic [31:0] a,          // forwarded rs1 (valid in capture cycle)
  input  logic [31:0] b,          // forwarded rs2 (valid in capture cycle)
  // ID/EX operand flops (a / b when no EX/MEM forward hits) and the forward
  // hit flag (fwd_rs1_sel | fwd_rs2_sel): fast-path DSP operands. Unused
  // under RISCV_FORMAL_ALTOPS.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] a_id,
  input  logic [31:0] b_id,
  input  logic        fwd_hit,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic        busy,       // M-op in EX still waiting for result
  output logic        res_valid,  // result valid (MUL low word: from pp flops)
  output logic [31:0] result,
  output logic [31:0] a_q,        // captured raw operands
  output logic [31:0] b_q
);

  /* verilator lint_off UNUSEDPARAM */
  localparam logic [2:0] S_IDLE     = 3'd0;
  localparam logic [2:0] S_MUL1     = 3'd1;
  localparam logic [2:0] S_MUL2     = 3'd2;
  localparam logic [2:0] S_MUL3     = 3'd3;
  localparam logic [2:0] S_DIV_INIT = 3'd4;
  localparam logic [2:0] S_DIV_RUN  = 3'd5;
  localparam logic [2:0] S_DIV_FIN  = 3'd6;
  localparam logic [2:0] S_ALT      = 3'd7;
  /* verilator lint_on UNUSEDPARAM */

  logic [2:0] state;
  logic [4:0] op_q;

  assign busy = start && !res_valid;

  // ── Operand / op capture ─────────────────────────────────────────────
  logic cap;
  assign cap = (state == S_IDLE) && !res_valid && !stall;

  always_ff @(posedge clock) begin
    if (cap) begin
      a_q  <= a;
      b_q  <= b;
      op_q <= op;
    end
  end

`ifdef RISCV_FORMAL_ALTOPS
  // ── ALTOPS stand-in: same handshake, algebraic result ────────────────
  // Constants mirror riscv-formal's insn_*.v ALTOPS definitions (and the
  // previous alu.sv).
  logic [31:0] alt_result;
  always_comb begin
    case (op_q)
      ALU_MUL:    alt_result = (a_q + b_q) ^ 32'h5876063e;
      ALU_MULH:   alt_result = (a_q + b_q) ^ 32'hf6583fb7;
      ALU_MULHU:  alt_result = (a_q + b_q) ^ 32'h949ce5e8;
      ALU_MULHSU: alt_result = (a_q - b_q) ^ 32'hecfbe137;
      ALU_DIV:    alt_result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU:   alt_result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:    alt_result = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU:   alt_result = (a_q - b_q) ^ 32'h3138d0e1;
      default:    alt_result = 32'b0;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state     <= S_IDLE;
      res_valid <= 1'b0;
    end else if (!stall) begin
      if (res_valid) begin
        res_valid <= 1'b0;             // EX/MEM accepts the result
      end else if (state == S_IDLE) begin
        if (start) state <= S_ALT;
      end else begin                   // S_ALT
        state     <= S_IDLE;
        res_valid <= 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (!stall && state == S_ALT) result <= alt_result;
  end

`else
  // ── Multiplier datapath ──────────────────────────────────────────────
  // DSP operands: the ID/EX flops in the op's first EX cycle (state IDLE,
  // select is a flop), the captured a_q / b_q / op_q afterwards. The sign
  // select likewise comes from `op` (ID/EX flops) in E0, op_q later.
  logic        idle_sel;
  logic [31:0] m_a, m_b;
  logic [4:0]  m_op;
  logic        a_sgn, b_sgn;
  logic [32:0] ea, eb;
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [33:0] p_ll, p_lh, p_hl, p_hh;   // only [31:0] of ll/hh used
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    idle_sel = (state == S_IDLE);
    m_a   = idle_sel ? a_id : a_q;
    m_b   = idle_sel ? b_id : b_q;
    m_op  = idle_sel ? op   : op_q;
    a_sgn = (m_op != ALU_MULHU);
    b_sgn = (m_op == ALU_MUL) || (m_op == ALU_MULH);
    ea    = {a_sgn & m_a[31], m_a};
    eb    = {b_sgn & m_b[31], m_b};
    a_lo  = {1'b0, ea[15:0]};
    b_lo  = {1'b0, eb[15:0]};
    a_hi  = ea[32:16];
    b_hi  = eb[32:16];
    p_ll  = a_lo * b_lo;
    p_lh  = a_lo * b_hi;
    p_hl  = a_hi * b_lo;
    p_hh  = a_hi * b_hi;
  end

  // Partial-product flops: free-running (held only by stall). They are
  // stable from the cycle after the DSP stage (E0 fast path / MUL1 slow
  // path) because later states recompute the same products from a_q / b_q.
  logic [31:0]        pp_ll, pp_hh;
  logic signed [33:0] pp_lh, pp_hl;
  logic signed [34:0] mid;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0]        prod;          // only the high word is registered
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0]        result_q;      // MULH* / DIV* / REM* result register
  logic               mul_low_q;     // op is MUL: release the pp low-word sum

  always_ff @(posedge clock) begin
    if (!stall) begin
      pp_ll <= p_ll[31:0];
      pp_lh <= p_lh;
      pp_hl <= p_hl;
      pp_hh <= p_hh[31:0];
    end
  end

  always_ff @(posedge clock) begin
    if (cap) mul_low_q <= (op == ALU_MUL);
  end

  always_comb begin
    prod = {pp_hh, pp_ll} + ({{29{mid[34]}}, mid} << 16);
  end

  // MUL low word straight from the pp flops: the low half of ll plus the
  // low halves of lh + hl shifted up by 16.
  logic [31:0] mul_low_sum;
  always_comb begin
    mul_low_sum = pp_ll + {pp_lh[15:0] + pp_hl[15:0], 16'b0};
  end

  assign result = mul_low_q ? mul_low_sum : result_q;

  // ── Divider datapath ─────────────────────────────────────────────────
  logic        div_signed, is_rem, sa, sb, q_neg, r_neg;
  logic [31:0] quo, rem_r, dvsr;
  logic [4:0]  cnt;
  logic [32:0] sh;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] diff;               // [32] unused (borrow is [33])
  /* verilator lint_on UNUSEDSIGNAL */
  logic        ge;
  logic [31:0] fin_v, fin_n, fin_res;

  always_comb begin
    div_signed = (op_q == ALU_DIV) || (op_q == ALU_REM);
    is_rem     = (op_q == ALU_REM) || (op_q == ALU_REMU);
    sa         = div_signed && a_q[31];
    sb         = div_signed && b_q[31];
    q_neg      = sa ^ sb;
    r_neg      = sa;

    sh   = {rem_r, quo[31]};
    diff = {1'b0, sh} - {2'b00, dvsr};
    ge   = !diff[33];

    fin_v   = is_rem ? rem_r : quo;
    fin_n   = (is_rem ? r_neg : q_neg) ? (32'b0 - fin_v) : fin_v;
    fin_res = (b_q == 32'b0) ? (is_rem ? a_q : 32'hFFFFFFFF) : fin_n;
  end

  // ── Sequencer ────────────────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (reset) begin
      state     <= S_IDLE;
      res_valid <= 1'b0;
    end else if (!stall) begin
      if (res_valid) begin
        res_valid <= 1'b0;             // EX/MEM accepts the result
      end else begin
        case (state)
          S_IDLE:     if (start) begin
                        if (op >= ALU_DIV)      state     <= S_DIV_INIT;
                        else if (fwd_hit)       state     <= S_MUL1;   // slow path
                        else if (op == ALU_MUL) res_valid <= 1'b1;     // pp = DSP stage
                        else                    state     <= S_MUL2;
                      end
          S_MUL1:     if (mul_low_q) begin state <= S_IDLE; res_valid <= 1'b1; end
                      else           state <= S_MUL2;
          S_MUL2:     state <= S_MUL3;
          S_MUL3:     begin state <= S_IDLE; res_valid <= 1'b1; end
          S_DIV_INIT: state <= S_DIV_RUN;
          S_DIV_RUN:  if (cnt == 5'd31) state <= S_DIV_FIN;
          S_DIV_FIN:  begin state <= S_IDLE; res_valid <= 1'b1; end
          default:    state <= S_IDLE;
        endcase
      end
    end
  end

  // ── Datapath registers ───────────────────────────────────────────────
  always_ff @(posedge clock) begin
    if (!stall) begin
      case (state)
        S_MUL2: begin
          mid <= {pp_lh[33], pp_lh} + {pp_hl[33], pp_hl};
        end
        S_MUL3: begin
          result_q <= prod[63:32];     // MULH* only (MUL releases from pp)
        end
        S_DIV_INIT: begin
          quo   <= sa ? (32'b0 - a_q) : a_q;   // |dividend|, becomes quotient
          dvsr  <= sb ? (32'b0 - b_q) : b_q;   // |divisor|
          rem_r <= 32'b0;
          cnt   <= 5'd0;
        end
        S_DIV_RUN: begin
          rem_r <= ge ? diff[31:0] : sh[31:0];
          quo   <= {quo[30:0], ge};
          cnt   <= cnt + 5'd1;
        end
        S_DIV_FIN: begin
          result_q <= fin_res;
        end
        default: ;
      endcase
    end
  end
`endif

endmodule
