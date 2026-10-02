// rtl/hazard_unit.sv
//
// Interlocks load-use dependencies and the variable-latency execute unit.
// A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Load-use compares available raw fetch fields against a valid EX load.
// Redirect is deliberately absent: it reaches PC and ID/EX validity only,
// never the instruction data, source comparison, or ID payload enable.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic       id_ex_valid,
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       execute_wait,      // hold ID/EX while divider runs
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // valid-qualified EX/MEM ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       backend_hold,      // ID/EX payload and validity hold
  output logic       load_use,          // hold payload, annul validity
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay retained
);

  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    load_use = id_ex_valid && id_ex_mem_read && imem_ready
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    backend_hold  = dmem_stall || execute_wait;
    stall_if      = load_use || imem_stall || backend_hold;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: retain the previously-retired payload on dmem_stall,
    // but clear valid so we don't double-retire / double-write the regfile.
    // EX's captured operands no longer depend on this retained payload.
    hold_mem_wb   = dmem_stall;
  end

endmodule
