// rtl/forward_unit.sv
//
// Retimed operand forwarding. Compare the incoming decode source fields
// against the actual post-trap producers about to enter EX/MEM and MEM/WB.
// The selections capture alongside ID/EX and describe the following EX cycle:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the in-flight ALU result from the EX/MEM register
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Latency:        combinational in decode, registered by core at ID/EX capture.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] next_ex_mem_rd,
  input  logic       next_ex_mem_w_en,
  input  logic [4:0] next_mem_wb_rd,
  input  logic       next_mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (next_ex_mem_w_en && next_ex_mem_rd != 5'b0 && next_ex_mem_rd == id_rs1) fwd_rs1 = 2'd1;
    else if (next_mem_wb_w_en && next_mem_wb_rd != 5'b0 && next_mem_wb_rd == id_rs1) fwd_rs1 = 2'd2;
    else                                                                  fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (next_ex_mem_w_en && next_ex_mem_rd != 5'b0 && next_ex_mem_rd == id_rs2) fwd_rs2 = 2'd1;
    else if (next_mem_wb_w_en && next_mem_wb_rd != 5'b0 && next_mem_wb_rd == id_rs2) fwd_rs2 = 2'd2;
    else                                                                  fwd_rs2 = 2'd0;
  end

endmodule
