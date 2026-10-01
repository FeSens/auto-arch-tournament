// rtl/forward_unit.sv
//
// EX operand forwarding for the immediately preceding producer.
// Older EX/MEM values are captured in ID and older still values arrive
// through the regfile's write-through read path.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       rs1_ex_mem_match,
  input  logic       rs2_ex_mem_match,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Destination equality is precomputed in ID; only the current producer's
  // write enable and x0 qualification remain on the EX forwarding path.
  always_comb begin
    if (ex_mem_w_en && ex_mem_rd != 5'b0 && rs1_ex_mem_match)
      fwd_rs1 = 2'd1;
    else
      fwd_rs1 = 2'd0;
  end

  always_comb begin
    if (ex_mem_w_en && ex_mem_rd != 5'b0 && rs2_ex_mem_match)
      fwd_rs2 = 2'd1;
    else
      fwd_rs2 = 2'd0;
  end

endmodule
