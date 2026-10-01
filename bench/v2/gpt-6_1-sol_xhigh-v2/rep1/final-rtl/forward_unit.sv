// rtl/forward_unit.sv
//
// Decode-side forwarding choice for the offered instruction. Producers
// are those entering EX/MEM (near) and MEM/WB (far) on its capture edge.
// Their permissions already include validity and alignment-trap cancellation.
//   001 : next EX/MEM result
//   010 : next MEM/WB unified result
//   100 : saved write-first RF value
//
// Resolve newest-writer priority before registering the operand selections.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] near_rd,
  input  logic       near_write,
  input  logic [4:0] far_rd,
  input  logic       far_write,
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (near_write && near_rd != 5'b0 && near_rd == id_rs1) fwd_rs1 = 3'b001;
    else if (far_write  && far_rd  != 5'b0 && far_rd  == id_rs1) fwd_rs1 = 3'b010;
    else                                                     fwd_rs1 = 3'b100;
  end

  always_comb begin
    if      (near_write && near_rd != 5'b0 && near_rd == id_rs2) fwd_rs2 = 3'b001;
    else if (far_write  && far_rd  != 5'b0 && far_rd  == id_rs2) fwd_rs2 = 3'b010;
    else                                                     fwd_rs2 = 3'b100;
  end

endmodule
