// rtl/forward_unit.sv
//
// Operand forwarding. For each rs in the EX-stage's source list, picks
// where the freshest value lives:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the in-flight ALU result from the EX/MEM register
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Dependency comparisons finish at the ID/EX boundary. Only registered
// matches and the actual producer write eligibility select EX operands.
// Latency:        matches capture with ID/EX; selection is combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       stall_id,
  input  logic       stall_ex_mem,
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic       mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  logic rs1_ex_match_q, rs2_ex_match_q;
  logic rs1_wb_match_q, rs2_wb_match_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      rs1_ex_match_q <= 1'b0;
      rs2_ex_match_q <= 1'b0;
      rs1_wb_match_q <= 1'b0;
      rs2_wb_match_q <= 1'b0;
    end else if (!stall_id) begin
      // Compare the queue head with the destinations moving into the
      // forwarding registers on this edge, including an M response.
      // Like the ID/EX payload, these enables are independent of flush.
      rs1_ex_match_q <= (if_id_rs1 != 5'b0) && (if_id_rs1 == id_ex_rd);
      rs2_ex_match_q <= (if_id_rs2 != 5'b0) && (if_id_rs2 == id_ex_rd);
      rs1_wb_match_q <= (if_id_rs1 != 5'b0) && (if_id_rs1 == ex_mem_rd);
      rs2_wb_match_q <= (if_id_rs2 != 5'b0) && (if_id_rs2 == ex_mem_rd);
    end else if (!stall_ex_mem) begin
      // A held consumer keeps its sources while the older EX/MEM
      // producer drains to WB and EX/MEM becomes a bubble. Never use
      // younger queue-head addresses to refresh a held instruction.
      rs1_wb_match_q <= rs1_ex_match_q;
      rs2_wb_match_q <= rs2_ex_match_q;
      rs1_ex_match_q <= 1'b0;
      rs2_ex_match_q <= 1'b0;
    end
    // A dmem hold retains both matches and forwarding payloads. WB valid
    // may clear, but its ctrl.reg_write and selected value remain alive.
  end

  always_comb begin
    if      (ex_mem_w_en && rs1_ex_match_q) fwd_rs1 = 2'd1;
    else if (mem_wb_w_en && rs1_wb_match_q) fwd_rs1 = 2'd2;
    else                                                                  fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_mem_w_en && rs2_ex_match_q) fwd_rs2 = 2'd1;
    else if (mem_wb_w_en && rs2_wb_match_q) fwd_rs2 = 2'd2;
    else                                                                  fwd_rs2 = 2'd0;
  end

endmodule
