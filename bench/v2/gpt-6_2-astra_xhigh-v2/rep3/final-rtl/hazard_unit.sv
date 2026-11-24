// rtl/hazard_unit.sv
//
// An immediate consumer of a divide/remainder or unverified
// load waits one cycle so WB can forward the result to its EX inputs.
//
// A load-use interlock retries the fetch and bubbles ID/EX. Data memory
// and divider waits hold the current ID/EX entry until EX can advance.
//
// The dependency and bypass result are latched alongside ID/EX.
// A dependent slot replays only if its load or divide result was late.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       id_ex_mem_result,  // load or divide in EX
  input  logic       bypass_ready,      // verified load result in EX
  input  logic [4:0] id_ex_rd,          // ID/EX.rd
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       div_wait,          // keep the issuing divide in ID/EX
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // A demand load or a store in EX/MEM needs the external data bus.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       replay,            // retry dependent fetch, squash ID/EX
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic dependent_q, bypass_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      dependent_q <= 1'b0;
    end else if (!stall_id) begin
      dependent_q <= id_ex_mem_result && id_ex_rd != 5'b0 &&
                     (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
      bypass_q    <= bypass_ready;
    end
  end
  assign replay       = dependent_q && !bypass_q;
  assign stall_ex_mem = !dmem_ready && ex_mem_mem_op;
  assign hold_mem_wb  = stall_ex_mem;
  assign stall_id     = stall_ex_mem || div_wait;
  assign stall_if     = stall_id || !imem_ready;

endmodule
