// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load/multiply/shift-use. These EX producers finish in MEM,
// so an instruction immediately behind that consumes their rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : hold the PC / ID/EX payload registers.
//   flush_if / flush_id : invalidate fetch and clear ID/EX controls on
//                          older EX/MEM recovery.
//   flush_id            : also clears ID/EX controls on late-result use to
//                          inject a single-cycle bubble between producer
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // LOAD, multiply, or shift in EX
  input  logic [4:0] id_ex_rd,          // late producer's destination
  input  logic [4:0] if_id_rs1,         // raw imem[19:15]     (next rs1)
  input  logic [4:0] if_id_rs2,         // raw imem[24:20]     (next rs2)
  input  logic       redirect,          // accepted older EX/MEM recovery
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  input  logic       execute_hold,      // divider holds PC and ID/EX only
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID valid -> 0
  output logic       flush_id,          // ID/EX ctrl + valid -> 0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

    // Unavailable imem bits cannot create a dependency. Qualification is
    // bus readiness only, so redirect never feeds the source comparisons
    // or the payload hold enables. Bubbles clear the registered mem_read.
  assign load_use_hazard = imem_ready && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
  assign imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
  assign stall_if      = load_use_hazard || imem_stall || dmem_stall || execute_hold;
    // Invalidate fetch when redirect squashes it or imem didn't deliver;
    // the raw payload remains independent of this late control.
  assign flush_if      = redirect || imem_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. Accepted older recovery
    // takes priority over every younger dependency or execute hold.
  assign stall_id      = dmem_stall || load_use_hazard || execute_hold;
  assign flush_id      = redirect || (load_use_hazard && !dmem_stall && !execute_hold);
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
  assign stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
  assign hold_mem_wb   = dmem_stall;

endmodule
