// Payload holds and validity kills are independent. A load bubble advances
// EX exactly once; divide wait drains older MEM/WB exactly once.
module hazard_unit (
  input logic load_use, redirect, div_wait, head_valid,
  input logic dmem_ready, ex_mem_mem_op,
  output logic decode_accept, operand_accept,
  output logic stall_id, flush_id, stall_of, flush_of,
  output logic stall_ex_mem, hold_mem_wb
);
  logic dmem_stall;
  assign dmem_stall = ex_mem_mem_op && !dmem_ready;
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb = dmem_stall;
  always_comb begin
    stall_id = dmem_stall || div_wait || load_use;
    stall_of = stall_id;
    flush_id = redirect;
    flush_of = redirect || (load_use && !dmem_stall && !div_wait);
    decode_accept = head_valid && !stall_id && !redirect;
    operand_accept = !stall_of && !redirect;
  end
endmodule
