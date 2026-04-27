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
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == id_ex_rs1) fwd_rs1 = 2'd1;
    else if (mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs1) fwd_rs1 = 2'd2;
    else                                                                  fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == id_ex_rs2) fwd_rs2 = 2'd1;
    else if (mem_wb_w_en && mem_wb_rd != 5'b0 && mem_wb_rd == id_ex_rs2) fwd_rs2 = 2'd2;
    else                                                                  fwd_rs2 = 2'd0;
  end

endmodule
