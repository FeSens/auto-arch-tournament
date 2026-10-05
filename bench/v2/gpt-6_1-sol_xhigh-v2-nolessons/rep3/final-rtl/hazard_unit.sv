// rtl/hazard_unit.sv
//
// Detects load-use hazards and holds the frontend while division owns EX.
// A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if        : hold the PC until a fetch can be accepted.
//   stall_id        : retain ID/EX only for backend memory/divider ownership.
//   flush_if/id     : kill fetch/ID/EX validity on redirect or load-use;
//                     the decoded payload still captures on those bubbles.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_valid,
  input  logic       if_id_valid,
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // EX has resolved a branch/jump
  input  logic       ex_divide_wait,    // hold frontend; older stages drain
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
  output logic       stall_id,          // ID/EX payload/valid retain ownership
  output logic       flush_if,          // fetch validity clears; raw payload stays
  output logic       flush_id,          // ID/EX validity clears; payload captures
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  // Preserve the original raw source-field comparisons, including fields
  // that encode immediates. Invalid loads and unavailable fetches are inert.
  assign load_use_hazard = id_ex_valid && if_id_valid && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
  assign imem_stall = !imem_ready;
  // dmem stall only matters if there's actually a memory op in EX/MEM
  // — otherwise bus-not-ready is irrelevant to the pipeline.
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // PC reg holds on any stall reason.
  assign stall_if = load_use_hazard || imem_stall || dmem_stall || ex_divide_wait;
  assign flush_if = redirect || imem_stall;
  // ID/EX register:
  //   - dmem_stall / divide_wait -> hold the instruction
  //   - load_use                -> bubble between LOAD + use
  //   - redirect                -> bubble to kill wrong-path
  //   - otherwise               -> capture
  // Re-evaluate load-use after a hold. Redirect retains its flush priority;
  // a divide cannot redirect. Neither EX/MEM nor MEM/WB freezes for division.
  assign stall_id = dmem_stall || ex_divide_wait;
  assign flush_id = (redirect || (load_use_hazard && !ex_divide_wait)) && !dmem_stall;
  // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
  // bus delivers).
  assign stall_ex_mem = dmem_stall;
  // MEM/WB register: on dmem_stall the previously-retired instruction's
  // data fields stay alive for forwarding (e.g. a held BNE needs the
  // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
  // double-retire / double-write the regfile.
  assign hold_mem_wb = dmem_stall;

endmodule
