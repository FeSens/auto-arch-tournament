// rtl/hazard_unit.sv
//
// Handles late-result hazards, the iterative divider, and bus backpressure.
// A LOAD or multiply in EX produces its data only after MEM,
// so an instruction immediately behind that consumes its rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : hold the PC and ID/EX respectively. Load-use
//                          also asserts flush_id to inject a bubble.
//   flush_if            : mask instruction bits only on unavailable imem.
//   flush_id            : on EX recovery, squash the younger instruction.
//                          Correct predictions have no redirect bubble.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // late-result producer (LOAD or multiply)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (producer's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // advancing EX misprediction
  input  logic       execute_wait,      // hold divide in ID/EX; drain MEM/WB
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
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  // Backpressure matters only for an older memory operation in EX/MEM.
  // Independent of recovery, which EX gates with this advance condition.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;
  assign stall_ex_mem = dmem_stall;
  // Recovery invalidates IF and clears ID/EX controls synchronously.
  // Only unavailable imem masks instruction bits and source addresses.
  assign flush_if = !imem_ready;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // IF's PC update gives recovery priority over all these holds.
    stall_if      = load_use_hazard || imem_stall || dmem_stall || execute_wait;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - execute_wait -> hold      (keep divide and prediction metadata)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // Both holds take precedence over load_use's bubble: re-evaluate
    // load_use when execution can advance. flush_id is 1 only when
    // we want bubble (not hold).
    stall_id      = dmem_stall || execute_wait || load_use_hazard;
    flush_id      = (load_use_hazard || redirect) && !dmem_stall && !execute_wait;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
