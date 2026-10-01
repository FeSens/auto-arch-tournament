// Operand forwarding and pipeline boundary between decode and execute.
// Forwarding is resolved here; execute sees registered, stable operands.
module operand_stage (
  input  logic       clock,
  input  logic       reset,
  input  logic       stall,
  input  logic       flush,
  input  id_ex_t     in,
  input  logic [1:0] fwd_rs1_sel,
  input  logic [1:0] fwd_rs2_sel,
  input  logic [31:0] fwd_ex_mem,
  input  logic [31:0] fwd_mem_wb,
  output id_ex_t     out
);

  logic [31:0] rs1;
  logic [31:0] rs2;
  id_ex_t reg_q;

  always_comb begin
    case (fwd_rs1_sel)
      2'd1:    rs1 = fwd_ex_mem;
      2'd2:    rs1 = fwd_mem_wb;
      default: rs1 = in.rs1_val;
    endcase
    case (fwd_rs2_sel)
      2'd1:    rs2 = fwd_ex_mem;
      2'd2:    rs2 = fwd_mem_wb;
      default: rs2 = in.rs2_val;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (stall) begin
      reg_q <= reg_q;
    end else if (flush) begin
      reg_q <= '0;
    end else begin
      reg_q <= in;
      reg_q.rs1_val <= rs1;
      reg_q.rs2_val <= rs2;
    end
  end

  assign out = reg_q;

endmodule
