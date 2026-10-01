`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
// One EX-owned request. MUL: launch DSP products, reduce, accept.
// DIV: raw launch, PREP, six LOOP edges, accept. Completion is
// frozen until accepted; there is no additional divider completion edge.
module m_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic        accept,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  localparam logic [1:0] IDLE = 2'd0, REDUCE = 2'd1,
                         MUL_DONE = 2'd2, DIV_RUN = 2'd3;
  logic [1:0] state_q;
`ifndef RISCV_FORMAL_ALTOPS
  logic [4:0] op_q;
`endif
  logic multiply_op, divide_op, launch, div_start, div_done;
  logic [31:0] div_result;
  /* verilator lint_off UNUSEDSIGNAL */
  logic div_busy;
  /* verilator lint_on UNUSEDSIGNAL */

  assign multiply_op = (op == ALU_MUL || op == ALU_MULH ||
                        op == ALU_MULHU || op == ALU_MULHSU);
  assign divide_op = (op == ALU_DIV || op == ALU_DIVU ||
                      op == ALU_REM || op == ALU_REMU);
  assign launch = start && state_q == IDLE && (multiply_op || divide_op);
  assign div_start = launch && divide_op;
  assign busy = state_q != IDLE;
  assign done = state_q == MUL_DONE || (state_q == DIV_RUN && div_done);

  div_unit u_div (
    .clock(clock), .reset(reset), .start(div_start),
    .accept(accept && state_q == DIV_RUN && div_done),
    .op(op), .a(a), .b(b), .busy(div_busy), .done(div_done), .result(div_result)
  );

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_launch_q, alt_product_q;
  assign result = state_q == DIV_RUN ? div_result : alt_product_q;
`else
  logic signed [16:0] high_a, high_b;
  assign high_a = $signed({(op == ALU_MULH || op == ALU_MULHSU) && a[31], a[31:16]});
  assign high_b = $signed({(op == ALU_MULH) && b[31], b[31:16]});

  // These are timed register boundaries, including when implemented in
  // DSP output registers. Preserve them against combinational absorption.
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [31:0] low_low_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic signed [33:0] low_high_q, high_low_q;
  /* verilator lint_off UNUSEDSIGNAL */
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic signed [33:0] high_high_q;
  /* verilator lint_on UNUSEDSIGNAL */
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [63:0] product_q;

  logic [63:0] term_ll, term_lh, term_hl, term_hh;
  logic [63:0] sum1, carry1, sum2, carry2;
  assign term_ll = {32'b0, low_low_q};
  assign term_lh = {{14{low_high_q[33]}}, low_high_q, 16'b0};
  assign term_hl = {{14{high_low_q[33]}}, high_low_q, 16'b0};
  // Only the low 32 bits survive this shift modulo 2^64.
  assign term_hh = {high_high_q[31:0], 32'b0};
  // Two carry-save levels, then one carry-propagating addition. No
  // serial chain of full-width additions between the product registers.
  assign sum1 = term_ll ^ term_lh ^ term_hl;
  assign carry1 = ((term_ll & term_lh) | (term_ll & term_hl) |
                   (term_lh & term_hl)) << 1;
  assign sum2 = sum1 ^ carry1 ^ term_hh;
  assign carry2 = ((sum1 & carry1) | (sum1 & term_hh) |
                   (carry1 & term_hh)) << 1;
  assign result = state_q == DIV_RUN ? div_result :
                  op_q == ALU_MUL ? product_q[31:0] : product_q[63:32];
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
`ifdef RISCV_FORMAL_ALTOPS
      alt_launch_q <= 32'b0;
      alt_product_q <= 32'b0;
`else
      op_q <= ALU_MUL;
      low_low_q <= 32'b0;
      low_high_q <= 34'b0;
      high_low_q <= 34'b0;
      high_high_q <= 34'b0;
      product_q <= 64'b0;
`endif
    end else begin
      case (state_q)
        IDLE: if (launch) begin
`ifndef RISCV_FORMAL_ALTOPS
          op_q <= op;
`endif
          if (multiply_op) begin
`ifdef RISCV_FORMAL_ALTOPS
            case (op)
              ALU_MUL:    alt_launch_q <= (a + b) ^ 32'h5876063e;
              ALU_MULH:   alt_launch_q <= (a + b) ^ 32'hf6583fb7;
              ALU_MULHU:  alt_launch_q <= (a + b) ^ 32'h949ce5e8;
              ALU_MULHSU: alt_launch_q <= (a - b) ^ 32'hecfbe137;
              default:    alt_launch_q <= 32'b0;
            endcase
`else
            low_low_q <= a[15:0] * b[15:0];
            low_high_q <= $signed({1'b0, a[15:0]}) * high_b;
            high_low_q <= high_a * $signed({1'b0, b[15:0]});
            high_high_q <= high_a * high_b;
`endif
            state_q <= REDUCE;
          end else state_q <= DIV_RUN;
        end
        REDUCE: begin
`ifdef RISCV_FORMAL_ALTOPS
          alt_product_q <= alt_launch_q;
`else
          product_q <= sum2 + carry2;
`endif
          state_q <= MUL_DONE;
        end
        MUL_DONE: if (accept) state_q <= IDLE;
        DIV_RUN: if (accept && div_done) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
