// rtl/forward_unit.sv
//
// Decode-stage operand forwarding. Compare IF/ID source addresses against
// the live writers and select the youngest available value. The current EX
// result is included to preserve zero-bubble ALU dependencies when ID/EX is
// captured on the same edge that the producer enters EX/MEM.
//
// Latency:        combinational.
// RVFI fields:    n/a — selects the operands captured in ID/EX and later
//                 reported as rs1_rdata / rs2_rdata.
module forward_unit (
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic [4:0] mem_load_rd,
  input  logic       mem_load_valid,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  // 0 = regfile, 1 = current EX result, 2 = EX/MEM ALU result,
  // 3 = ready MEM load result, 4 = MEM/WB writeback value.
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (id_ex_w_en   && id_ex_rd   != 5'b0 && id_ex_rd   == if_id_rs1) fwd_rs1 = 3'd1;
    else if (ex_mem_w_en  && ex_mem_rd  != 5'b0 && ex_mem_rd  == if_id_rs1) fwd_rs1 = 3'd2;
    else if (mem_load_valid && mem_load_rd != 5'b0 && mem_load_rd == if_id_rs1) fwd_rs1 = 3'd3;
    else if (mem_wb_w_en  && mem_wb_rd  != 5'b0 && mem_wb_rd  == if_id_rs1) fwd_rs1 = 3'd4;
    else                                                                         fwd_rs1 = 3'd0;
  end

  always_comb begin
    if      (id_ex_w_en   && id_ex_rd   != 5'b0 && id_ex_rd   == if_id_rs2) fwd_rs2 = 3'd1;
    else if (ex_mem_w_en  && ex_mem_rd  != 5'b0 && ex_mem_rd  == if_id_rs2) fwd_rs2 = 3'd2;
    else if (mem_load_valid && mem_load_rd != 5'b0 && mem_load_rd == if_id_rs2) fwd_rs2 = 3'd3;
    else if (mem_wb_w_en  && mem_wb_rd  != 5'b0 && mem_wb_rd  == if_id_rs2) fwd_rs2 = 3'd4;
    else                                                                         fwd_rs2 = 3'd0;
  end

endmodule
