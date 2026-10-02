// rtl/hazard_unit.sv
//
// Registered operand-read matches identify unavailable loads in EX.
// A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze the PC and decoded record respectively.
//   hold_ex             : retain complete ID/EX operands during genuine
//                         older memory waits or blocking EX work.
//   flush_id            : clear ID/EX on recovery or inject the load-use
//                          bubble. Accepted MEM recovery kills younger holds;
//                          genuine older MEM waits suppress acceptance.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       decoded_valid,
  input  logic       source_wait,      // registered EX match to unavailable load
  input  logic       redirect,          // accepted registered MEM recovery
  input  logic       execute_busy,      // division holds only IF and ID/EX
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // decoded record holds
  output logic       hold_ex,
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;
  assign load_use_hazard = decoded_valid && source_wait;
  // Unrelated dmem readiness never blocks a nonmemory MEM resolution.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;
  assign hold_ex = dmem_stall || execute_busy;
  assign stall_id = hold_ex || load_use_hazard;
  assign stall_if = stall_id || !imem_ready;
  assign flush_id = redirect || (load_use_hazard && !hold_ex);
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb = dmem_stall;

endmodule
