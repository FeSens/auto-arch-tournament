// rtl/forward_unit.sv
//
// Operand forwarding. For each raw source address being admitted in ID, picks
// where the freshest value lives:
//   00 (RF)  : write-first regfile read, including the oldest WB value
//   01 (EX)  : current advancing EX's architectural result (never a load)
//   10 (MEM) : current completing MEM's ALU result or extracted load data
//
// Producer enables include validity, completion and final trap controls.
// Priority is EX > MEM > RF (younger writer wins, x0 never matches).
//
// Latency:        combinational.
// RVFI fields:    n/a — resolves architectural operands before ID/EX.
module forward_unit (
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
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
    if      (if_id_rs1 != 5'b0 && ex_w_en && ex_rd != 5'b0 && ex_rd == if_id_rs1) fwd_rs1 = 2'd1;
    else if (if_id_rs1 != 5'b0 && mem_w_en && mem_rd != 5'b0 && mem_rd == if_id_rs1) fwd_rs1 = 2'd2;
    else                                                                        fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (if_id_rs2 != 5'b0 && ex_w_en && ex_rd != 5'b0 && ex_rd == if_id_rs2) fwd_rs2 = 2'd1;
    else if (if_id_rs2 != 5'b0 && mem_w_en && mem_rd != 5'b0 && mem_rd == if_id_rs2) fwd_rs2 = 2'd2;
    else                                                                        fwd_rs2 = 2'd0;
  end

endmodule
