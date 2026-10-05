// Shared RV32M multiplier. The request edge snapshots forwarded operands;
// four unsigned 16x16 products, reduction, high carry and signed corrections
// each have their own register boundary. MUL completes at reduction, without
// waiting for high-half arithmetic. Results remain stable until consumed.
`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
module multiplier (
  input  logic        clock,
  input  logic        reset,
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [4:0]  req_op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        result_valid,
  input  logic        result_ready,
  output logic [31:0] result
);
  localparam logic [2:0] IDLE = 3'd0, PRODUCTS = 3'd1, REDUCE = 3'd2,
                         HIGH = 3'd3, SUB_B = 3'd4, SUB_A = 3'd5,
                         DONE = 3'd6;
  logic [2:0] state_q;
  logic [4:0] op_q;
  logic [31:0] a_q, b_q;
  logic [31:0] ll_q, lh_q, hl_q, hh_q;
  logic [31:0] high_base_q;
  logic [1:0] carry_q;
  logic [17:0] column;

  assign req_ready = (state_q == IDLE) && !reset;
  assign result_valid = (state_q == DONE) && !reset;
  // Each addend is explicitly 18 bits: two carry bits must survive.
  assign column = {2'b0, ll_q[31:16]} + {2'b0, lh_q[15:0]}
                + {2'b0, hl_q[15:0]};

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q     <= IDLE;
      op_q        <= '0;
      a_q         <= '0;
      b_q         <= '0;
      ll_q        <= '0;
      lh_q        <= '0;
      hl_q        <= '0;
      hh_q        <= '0;
      high_base_q <= '0;
      carry_q     <= '0;
      result      <= '0;
    end else begin
      case (state_q)
        IDLE: if (req_valid && req_ready) begin
          a_q     <= a;
          b_q     <= b;
          op_q    <= req_op;
          state_q <= PRODUCTS;
        end
        PRODUCTS: begin
          ll_q <= a_q[15:0]  * b_q[15:0];
          lh_q <= a_q[15:0]  * b_q[31:16];
          hl_q <= a_q[31:16] * b_q[15:0];
          hh_q <= a_q[31:16] * b_q[31:16];
          state_q <= REDUCE;
        end
        REDUCE: begin
          high_base_q <= hh_q + {16'b0, lh_q[31:16]}
                             + {16'b0, hl_q[31:16]};
          carry_q <= column[17:16];
          if (op_q == ALU_MUL) begin
            result <= {column[15:0], ll_q[15:0]};
            state_q <= DONE;
          end else state_q <= HIGH;
        end
        HIGH: begin
          result <= high_base_q + {30'b0, carry_q};
          state_q <= (op_q == ALU_MULHU) ? DONE : SUB_B;
        end
        SUB_B: begin
          result <= a_q[31] ? result - b_q : result;
          state_q <= (op_q == ALU_MULHSU) ? DONE : SUB_A;
        end
        SUB_A: begin
          result <= b_q[31] ? result - a_q : result;
          state_q <= DONE;
        end
        DONE: if (result_ready) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
