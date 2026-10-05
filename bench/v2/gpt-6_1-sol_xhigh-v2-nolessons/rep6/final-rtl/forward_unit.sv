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
// Raw dependency comparisons are registered with ID/EX advancement. The
// compared ID/EX and EX/MEM producers become EX/MEM and MEM/WB on that
// edge. Only their CURRENT write controls qualify the matches in EX.
//
// Latency:        ID-aligned match registers; combinational EX selectors.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       stall,
  input  logic       flush,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic       mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  logic rs1_ex_match_q, rs2_ex_match_q;
  logic rs1_wb_match_q, rs2_wb_match_q;

  // Match ID's control-register priority: load-use flush overrides stall,
  // while hazard_unit suppresses flush during genuine dmem/divider holds.
  // Compare raw source addresses independently of fetch validity/redirect.
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      rs1_ex_match_q <= 1'b0;
      rs2_ex_match_q <= 1'b0;
      rs1_wb_match_q <= 1'b0;
      rs2_wb_match_q <= 1'b0;
    end else if (!stall) begin
      rs1_ex_match_q <= (id_ex_rd != 5'b0) && (id_ex_rd == id_rs1);
      rs2_ex_match_q <= (id_ex_rd != 5'b0) && (id_ex_rd == id_rs2);
      rs1_wb_match_q <= (ex_mem_rd != 5'b0) && (ex_mem_rd == id_rs1);
      rs2_wb_match_q <= (ex_mem_rd != 5'b0) && (ex_mem_rd == id_rs2);
    end
  end

  // Current controls include alignment traps and divider bubbles. MEM/WB
  // valid/w_en must NOT gate forwarding: a dmem hold retains its producer
  // data and reg_write after clearing valid to prevent double retirement.
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
