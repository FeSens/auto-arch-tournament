// Load-use waits one edge for MEM forwarding. A divide holds ID/EX while
// older stages drain, and a pending dmem access retains both stages.
module hazard_unit (
  input  logic       load_use,
  input  logic       repair,
  input  logic       divide_wait,
  input  logic       dmem_ready,
  input  logic       ex_mem_mem_op,
  output logic       issue_if,
  output logic       stall_id,
  output logic       flush_id,
  output logic       stall_ex_mem,
  output logic       hold_mem_wb
);

  assign stall_ex_mem = ex_mem_mem_op && !dmem_ready;
  assign stall_id = stall_ex_mem || divide_wait;
  assign flush_id = repair || (load_use && !stall_id);
  assign issue_if = !stall_id && !load_use && !repair;
  assign hold_mem_wb = stall_ex_mem || repair;

endmodule
