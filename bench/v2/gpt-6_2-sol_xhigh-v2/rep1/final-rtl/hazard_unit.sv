// rtl/hazard_unit.sv
//
// Handles bus backpressure, divider waits, and load-use replay.
module hazard_unit (
  input  logic       div_wait,          // EX is holding a divide/remainder
  input  logic       load_replay,
  input  logic       dmem_ready,
  input  logic       ex_mem_mem_op,
  output logic       hold_id,           // older instruction still in EX
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic dmem_stall;

  assign dmem_stall = !dmem_ready && ex_mem_mem_op;
  assign hold_id = dmem_stall || div_wait || load_replay;
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb = dmem_stall;

endmodule
