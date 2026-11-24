// Choose each decode operand's producer for the next cycle in EX.
// EX has priority over MEM when both eligible writers match.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] ex_rd,
  input  logic       ex_write_eligible,
  input  logic [4:0] mem_rd,
  input  logic       mem_write_eligible,
  output operand_sel_t rs1_sel,
  output operand_sel_t rs2_sel
);

  logic ex_writes, mem_writes;
  logic rs1_ex, rs1_mem, rs2_ex, rs2_mem;

  assign ex_writes  = ex_write_eligible  && (ex_rd  != 5'b0);
  assign mem_writes = mem_write_eligible && (mem_rd != 5'b0);

  assign rs1_ex  = ex_writes  && (ex_rd  == id_rs1);
  assign rs1_mem = mem_writes && (mem_rd == id_rs1);
  assign rs2_ex  = ex_writes  && (ex_rd  == id_rs2);
  assign rs2_mem = mem_writes && (mem_rd == id_rs2);

  assign rs1_sel = {rs1_ex, rs1_mem && !rs1_ex, !(rs1_ex || rs1_mem)};
  assign rs2_sel = {rs2_ex, rs2_mem && !rs2_ex, !(rs2_ex || rs2_mem)};

endmodule
