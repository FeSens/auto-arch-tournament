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
// Address matches are prepared before the ID/EX edge. The EX selection
// only qualifies that metadata with the actual producer write controls.
// Latency:        no added instruction stage.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       stall_id,
  input  logic       stall_ex_mem,
  input  logic       hold_mem_wb,
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  logic [4:0] next_rs1, next_rs2, next_ex_rd, next_wb_rd;
  logic rs1_ex_match_q, rs2_ex_match_q, rs1_wb_match_q, rs2_wb_match_q;
  assign next_rs1 = stall_id ? id_ex_rs1 : if_id_rs1;
  assign next_rs2 = stall_id ? id_ex_rs2 : if_id_rs2;
  assign next_ex_rd = stall_ex_mem ? ex_mem_rd : id_ex_rd;
  assign next_wb_rd = hold_mem_wb ? mem_wb_rd : ex_mem_rd;

  // Refresh even when ID/EX holds: older producers can drain during a
  // divide. A cleared EX/MEM or faulting producer is suppressed by its
  // live reg_write below. A flushed consumer cannot use stale matches.
  always_ff @(posedge clock) begin
    if (reset) begin
      rs1_ex_match_q <= 1'b0;
      rs2_ex_match_q <= 1'b0;
      rs1_wb_match_q <= 1'b0;
      rs2_wb_match_q <= 1'b0;
    end else begin
      rs1_ex_match_q <= (next_rs1 != 5'b0) && (next_rs1 == next_ex_rd);
      rs2_ex_match_q <= (next_rs2 != 5'b0) && (next_rs2 == next_ex_rd);
      rs1_wb_match_q <= (next_rs1 != 5'b0) && (next_rs1 == next_wb_rd);
      rs2_wb_match_q <= (next_rs2 != 5'b0) && (next_rs2 == next_wb_rd);
    end
  end

  // MEM/WB remains a forwarding source when hold_mem_wb clears valid
  // while retaining its data and control; do not qualify with valid.
  always_comb begin
    if      (ex_mem_w_en && rs1_ex_match_q) fwd_rs1 = 2'd1;
    else if (mem_wb_w_en && rs1_wb_match_q) fwd_rs1 = 2'd2;
    else                                  fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_mem_w_en && rs2_ex_match_q) fwd_rs2 = 2'd1;
    else if (mem_wb_w_en && rs2_wb_match_q) fwd_rs2 = 2'd2;
    else                                  fwd_rs2 = 2'd0;
  end

endmodule
