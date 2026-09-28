// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
// Also interlocks IF/ID behind a divide without holding the older stages.
//
// Outputs:
//   stall_if            : freeze the PC on any unaccepted fetch.
//   stall_id            : hold ID/EX only for actual memory/divide waits.
//   flush_if / flush_id : on EX misprediction, kill the one younger
//                          issue slot (IF/ID is combinational).
//   flush_id            : also clears ID/EX controls/valid on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // advancing EX prediction mismatch
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  input  logic       div_wait,          // EX long op; older stages still drain
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX controls/valid capture '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  // Separate equations keep the redirect -> flush path independent of
  // the flushed instruction's source fields (no false combinational loop).
  assign load_use_hazard = id_ex_mem_read
                       && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                       && (id_ex_rd != 5'b0);
  assign imem_stall = !imem_ready;
  // dmem stall only matters if there's actually a memory op in EX/MEM
  // — otherwise bus-not-ready is irrelevant to the pipeline.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // PC reg holds on any stall reason.
  assign stall_if = load_use_hazard || imem_stall || dmem_stall || div_wait;
  // IF/ID combinational payload: NOP whenever we wouldn't have a valid
  // instruction this cycle (EX recovery, or imem didn't deliver).
  assign flush_if = redirect || imem_stall;
  // ID/EX register:
  //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
  //   - div_wait    -> hold        (EX supplies full downstream bubbles)
  //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
  //   - redirect    -> bubble      (kill wrong-path)
  //   - otherwise   -> capture
  // dmem_stall takes precedence over load_use's bubble: re-evaluate
  // load_use next cycle when the bus unblocks. A load-use bubble clears
  // controls/valid while payload captures the still-unaccepted fetch;
  // the held fetch is accepted normally on the next eligible edge.
  assign stall_id = dmem_stall || div_wait;
  assign flush_id = (load_use_hazard || redirect) && !dmem_stall && !div_wait;
  // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
  // bus delivers).
  assign stall_ex_mem = dmem_stall;
  // MEM/WB register: on dmem_stall the previously-retired instruction's
  // data fields stay alive for forwarding (e.g. a held BNE needs the
  // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
  // double-retire / double-write the regfile.
  assign hold_mem_wb = dmem_stall;

endmodule
