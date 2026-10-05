// OF selection: youngest accepted EX writer, MEM, WB, then current RF.
module forward_unit (
  input logic [4:0] rs1_addr, rs2_addr,
  input logic [4:0] ex_rd, mem_rd, wb_rd,
  input logic ex_w_en, mem_w_en, wb_w_en,
  output logic [1:0] fwd_rs1, fwd_rs2
);
  always_comb begin
    if (rs1_addr == 0) fwd_rs1 = 0;
    else if (ex_w_en && ex_rd != 0 && ex_rd == rs1_addr) fwd_rs1 = 1;
    else if (mem_w_en && mem_rd != 0 && mem_rd == rs1_addr) fwd_rs1 = 2;
    else if (wb_w_en && wb_rd != 0 && wb_rd == rs1_addr) fwd_rs1 = 3;
    else fwd_rs1 = 0;
    if (rs2_addr == 0) fwd_rs2 = 0;
    else if (ex_w_en && ex_rd != 0 && ex_rd == rs2_addr) fwd_rs2 = 1;
    else if (mem_w_en && mem_rd != 0 && mem_rd == rs2_addr) fwd_rs2 = 2;
    else if (wb_w_en && wb_rd != 0 && wb_rd == rs2_addr) fwd_rs2 = 3;
    else fwd_rs2 = 0;
  end
endmodule
