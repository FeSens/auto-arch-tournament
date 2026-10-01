// rtl/forward_unit.sv
//
// Decode lookahead: choose where each fetched source will live after the
// next ID/EX acceptance edge. Current WB collisions use RF write-first.
//   00 : captured RF operand
//   01 : advancing EX scalar/M token's next EX/MEM result
//   10 : current MEM token's next MEM/WB result (including load data)
//
// Priority is EX > MEM > RF (younger writer wins, x0 is never a producer).
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] ex_rd,
  input  logic       ex_w_en,
  input  logic [4:0] mem_rd,
  input  logic       mem_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (ex_w_en && ex_rd != 5'b0 && ex_rd == id_rs1) fwd_rs1 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs1) fwd_rs1 = 2'd2;
    else                                                                  fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_w_en && ex_rd != 5'b0 && ex_rd == id_rs2) fwd_rs2 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs2) fwd_rs2 = 2'd2;
    else                                                                  fwd_rs2 = 2'd0;
  end

endmodule
