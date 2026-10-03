// rtl/forward_unit.sv
//
// Registered forwarding-plan precompute. For each raw source register of the
// instruction being accepted into ID/EX, pick where the freshest value will
// live when that instruction reaches EX on the next cycle:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : current ID/EX writer after it advances into EX/MEM
//   10 (MEM_WB)  : current EX/MEM writer after it advances into MEM/WB
//
// Priority is current ID/EX > current EX/MEM > none (younger writer wins,
// x0 always reads as zero). The selected bits are registered with the
// consumer instruction and used directly by EX.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] fetch_rs1,
  input  logic [4:0] fetch_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (id_ex_w_en  && id_ex_rd  != 5'b0 && id_ex_rd  == fetch_rs1) fwd_rs1 = FWD_EX_MEM;
    else if (ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == fetch_rs1) fwd_rs1 = FWD_MEM_WB;
    else                                                                 fwd_rs1 = FWD_NONE;
  end

  always_comb begin
    if      (id_ex_w_en  && id_ex_rd  != 5'b0 && id_ex_rd  == fetch_rs2) fwd_rs2 = FWD_EX_MEM;
    else if (ex_mem_w_en && ex_mem_rd != 5'b0 && ex_mem_rd == fetch_rs2) fwd_rs2 = FWD_MEM_WB;
    else                                                                 fwd_rs2 = FWD_NONE;
  end

endmodule
