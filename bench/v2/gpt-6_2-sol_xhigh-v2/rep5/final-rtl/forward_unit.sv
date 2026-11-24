// rtl/forward_unit.sv
//
// Compare encoded sources in decode. On the issue edge, the current EX
// and MEM producers move to EX/MEM and MEM/WB. The current WB producer
// is already bypassed by the register file read ports.
module forward_unit (
  input  logic [4:0] rs1_addr,
  input  logic [4:0] rs2_addr,
  input  logic       rs1_nonzero,
  input  logic       rs2_nonzero,
  input  logic [4:0] ex_rd,
  input  logic       ex_fast_write,
  input  logic [4:0] mem_rd,
  input  logic       mem_write,
  output operand_sel_t rs1_sel,
  output operand_sel_t rs2_sel
);

  logic ex_writes_rd, mem_writes_rd;

  assign ex_writes_rd  = ex_fast_write && ex_rd != 5'b0;
  assign mem_writes_rd = mem_write && mem_rd != 5'b0;

  function automatic operand_sel_t select_operand (
    input logic [4:0] addr,
    input logic       nonzero
  );
    logic ex_match, mem_match;
    operand_sel_t sel;

    ex_match  = ex_writes_rd && ex_rd == addr;
    mem_match = mem_writes_rd && mem_rd == addr;

    sel.ex_mem   = ex_match;
    sel.mem_wb   = !ex_match && mem_match;
    sel.reg_file = nonzero && !ex_match && !mem_match;
    select_operand = sel;
  endfunction

  always_comb begin
    rs1_sel = select_operand(rs1_addr, rs1_nonzero);
    rs2_sel = select_operand(rs2_addr, rs2_nonzero);
  end

endmodule
