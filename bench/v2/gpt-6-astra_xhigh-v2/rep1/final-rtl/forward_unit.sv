// rtl/forward_unit.sv
//
// Prospective operand forwarding for the instruction currently in decode.
// Producer tags/flags describe where values will be after its ID/EX edge.
// The one-hot source enables are captured alongside the operand values:
//   bit 0 : ID/EX register's rs?_val
//   bit 1 : EX/MEM ALU result (younger producer)
//   bit 2 : MEM/WB write-data mux (older producer)
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  always_comb begin
    fwd_rs1[1] = ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == id_rs1;
    fwd_rs1[2] = mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_rs1
                 && !fwd_rs1[1];
    fwd_rs1[0] = !(fwd_rs1[1] || fwd_rs1[2]);
  end

  always_comb begin
    fwd_rs2[1] = ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == id_rs2;
    fwd_rs2[2] = mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_rs2
                 && !fwd_rs2[1];
    fwd_rs2[0] = !(fwd_rs2[1] || fwd_rs2[2]);
  end

endmodule
