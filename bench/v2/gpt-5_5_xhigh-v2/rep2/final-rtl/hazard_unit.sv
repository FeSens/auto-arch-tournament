// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   if_pop        : queued IF payload is accepted by decode this cycle.
//   hold_id       : hold the entire ID/EX register for a true pipeline hold.
//   bubble_id     : clear only ID/EX ctrl/valid; payload may still capture.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       if_id_valid,       // front-end queue has/bypasses work
  input  logic       redirect,          // EX has resolved a branch/jump
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). Dmem backpressure still freezes
  // the architectural pipeline; imem backpressure is absorbed by IF queue
  // state and appears here only as if_id_valid=0 when the queue is empty.
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // Sequential EX substage is holding a MUL/DIV/REM instruction. Decode-pop
  // is held and ID/EX bubbles until the completed result is written into
  // EX/MEM; the IF queue may keep filling.
  input  logic       ex_busy,
  output logic       if_pop,            // IF queue/decode handshake
  output logic       hold_id,           // ID/EX whole-register hold
  output logic       bubble_id,         // ID/EX ctrl/valid capture bubble
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = if_id_valid && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // Decode accepts exactly one queued/bypassed instruction when there is
    // real work and no backend reason to hold it in the front end.
    if_pop        = if_id_valid && !load_use_hazard && !redirect
                    && !dmem_stall && !ex_busy;
    // ID/EX register:
    //   - dmem_stall  -> hold whole bundle (older memory op blocks pipe)
    //   - load_use    -> bubble ctrl/valid only (1-cycle gap after LOAD)
    //   - !if_id_valid -> bubble ctrl/valid only (queue empty, imem stalled)
    //   - ex_busy     -> bubble ctrl/valid only (M op owns EX)
    //   - redirect    -> bubble ctrl/valid only (kill wrong-path)
    //   - otherwise   -> capture payload and decoded control
    // dmem_stall takes precedence so all ID/EX state is re-evaluated only
    // after the older memory op is allowed to advance.
    hold_id       = dmem_stall;
    bubble_id     = (load_use_hazard || redirect || !if_id_valid || ex_busy)
                    && !dmem_stall;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
