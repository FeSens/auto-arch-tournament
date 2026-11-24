// rtl/forward_unit.sv
//
// Compare the raw decode sources against EX and MEM writers. The selects
// advance to EX with the consumer as the writers advance to MEM and WB.
module forward_unit (
  input  logic [4:0]  id_rs1,
  input  logic [4:0]  id_rs2,
  input  logic [4:0]  ex_rd,
  input  logic        ex_write,
  input  logic [4:0]  mem_rd,
  input  logic        mem_write,
  output operand_sel_t rs1_sel,
  output operand_sel_t rs2_sel
);

  logic ex_eligible, mem_eligible;
  assign ex_eligible  = ex_write && ex_rd != 5'b0;
  assign mem_eligible = mem_write && mem_rd != 5'b0;

  function automatic operand_sel_t select_source(input logic ex_match, mem_match);
    operand_sel_t sel;
    sel.local_value = !ex_match && !mem_match;
    sel.ex_mem      = ex_match;
    sel.mem_wb      = !ex_match && mem_match;
    select_source   = sel;
  endfunction

  assign rs1_sel = select_source(ex_eligible && ex_rd == id_rs1,
                                 mem_eligible && mem_rd == id_rs1);
  assign rs2_sel = select_source(ex_eligible && ex_rd == id_rs2,
                                 mem_eligible && mem_rd == id_rs2);

endmodule
