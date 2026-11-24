// rtl/forward_unit.sv
//
// Decode compares each fetched source with the writers in EX and MEM.
// The result identifies where the operand will be on the next EX cycle:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the youngest writer, split into ALU/load/link or
//                  product by the registered bypass controls in core
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
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
    if      (ex_w_en  && ex_rd  != 5'b0 && ex_rd  == id_rs1) fwd_rs1 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs1) fwd_rs1 = 2'd2;
    else                                                     fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_w_en  && ex_rd  != 5'b0 && ex_rd  == id_rs2) fwd_rs2 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs2) fwd_rs2 = 2'd2;
    else                                                     fwd_rs2 = 2'd0;
  end

endmodule
