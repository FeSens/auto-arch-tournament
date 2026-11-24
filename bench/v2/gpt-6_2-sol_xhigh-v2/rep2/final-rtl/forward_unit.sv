// rtl/forward_unit.sv
//
// Qualify the registered, nonzero tag matches with the producer write
// enables. Each operand selects one source in {EX/MEM, MEM/WB, ID/EX} order.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [1:0] match_ex_mem, // {rs2, rs1}
  input  logic [1:0] match_mem_wb, // {rs2, rs1}
  input  logic       ex_mem_w_en,
  input  logic       mem_wb_w_en,
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  logic [1:0] ex_mem_match, mem_wb_match;
  logic [1:0] select_mem_wb, select_id_ex;

  assign ex_mem_match  = match_ex_mem & {2{ex_mem_w_en}};
  assign mem_wb_match  = match_mem_wb & {2{mem_wb_w_en}};
  assign select_mem_wb = ~ex_mem_match & mem_wb_match;
  assign select_id_ex  = ~(ex_mem_match | mem_wb_match);

  assign fwd_rs1 = {ex_mem_match[0], select_mem_wb[0], select_id_ex[0]};
  assign fwd_rs2 = {ex_mem_match[1], select_mem_wb[1], select_id_ex[1]};

endmodule
