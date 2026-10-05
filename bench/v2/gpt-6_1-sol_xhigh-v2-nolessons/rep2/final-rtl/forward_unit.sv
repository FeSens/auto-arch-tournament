// rtl/forward_unit.sv
//
// Operand forwarding. For each encoded rs in ID's source list, picks
// where the freshest value lives:
//   00 (RF)  : current regfile read, including its WB write-first bypass
//   01 (EX)  : current EX architectural result (loads are unavailable)
//   10 (MEM) : current MEM architectural result, including load extraction
//
// Producer enables include validity and effective, nontrapping writes.
// Priority is EX > MEM > RF; x0 never matches a producer.
//
// Latency:        combinational.
// RVFI fields:    feeds rs1_rdata / rs2_rdata before ID/EX capture.
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
    else                                                fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_w_en && ex_rd != 5'b0 && ex_rd == id_rs2) fwd_rs2 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs2) fwd_rs2 = 2'd2;
    else                                                fwd_rs2 = 2'd0;
  end

endmodule
