// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze the PC reg and the IF/ID combinational
//                          payload (cleared by ID's flush input).
//   flush_if / flush_id : on EX redirect, kill the two in-flight
//                          instructions ahead of the redirect target.
//   flush_id            : also kills ID's own register on load-use to
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
  input  logic       redirect,          // EX has resolved a branch/jump
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // ex_stage asserts this while an iterative divide is mid-flight in
  // EX. It must hold the same stages dmem_stall holds (IF, ID, EX/MEM,
  // MEM/WB) so the divide retains its pipeline slot for the full 33
  // cycles. Mutually exclusive with dmem_stall in practice — div_busy
  // means a div is in EX, dmem_stall means a memory op is in EX/MEM —
  // but the OR-priority is safe in either order.
  input  logic       div_busy,
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

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    stall_if      = load_use_hazard || imem_stall || dmem_stall || div_busy;
    // IF/ID combinational payload: NOP whenever we wouldn't have a valid
    // instruction this cycle (redirect target unknown to IF, or imem
    // didn't deliver). div_busy holds the PC, so IF re-presents the same
    // instruction each cycle to ID — no flush needed.
    flush_if      = redirect || imem_stall;
    // ID/EX register:
    //   - dmem_stall / div_busy -> hold (preserve in-flight pipeline)
    //   - load_use              -> bubble (1-cycle stall between LOAD+use)
    //   - redirect              -> bubble (kill wrong-path)
    //   - otherwise             -> capture
    // dmem_stall / div_busy take precedence over load_use's bubble:
    // re-evaluate load_use next cycle when the bus / divide unblocks.
    // flush_id is 1 only when we want bubble (not hold).
    stall_id      = dmem_stall || load_use_hazard || div_busy;
    flush_id      = (load_use_hazard || redirect) && !dmem_stall && !div_busy;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers) or div_busy (DIV/REM result not ready yet).
    stall_ex_mem  = dmem_stall || div_busy;
    // MEM/WB register: on either stall the previously-retired
    // instruction's data fields stay alive for forwarding (e.g. a held
    // BNE needs the LOAD's load_data via fwd_mem_wb), but valid is
    // cleared so we don't double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall || div_busy;
  end

endmodule
