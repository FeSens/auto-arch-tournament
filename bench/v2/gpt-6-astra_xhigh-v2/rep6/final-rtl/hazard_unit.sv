// rtl/hazard_unit.sv
//
// Loads and M operations finish in M. A matching D source waits for X to
// advance, injecting exactly one X bubble. Memory holds and active divider
// rounds take precedence and preserve the complete resolved X operands.
//
// Backend hold is independent of instruction readiness and recovery.
// The fetch ring can fill during holds and issue through instruction waits.
// Dependency bubbles clear ID/EX; recovery is annulled by X's kill register.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       operand_wait,      // youngest X writer is a load or M op
  input  logic       execute_wait,      // block IF + ID/EX, drain older work
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // backend holds ring head
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // clear ID/EX valid and controls
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // retain already captured W data
);

  logic dmem_stall;
  logic backend_hold;

  assign dmem_stall = !dmem_ready && ex_mem_mem_op;
  assign backend_hold = operand_wait || dmem_stall || execute_wait;
  assign stall_if = backend_hold;
  assign stall_id = backend_hold;
  assign flush_id = operand_wait && !dmem_stall && !execute_wait;
  // Separate assignments make the absence of recovery feedback into the
  // actual dmem hold explicit to simulation and synthesis alike.
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb = dmem_stall;

endmodule
