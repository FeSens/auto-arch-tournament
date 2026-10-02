// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle. A MUL/MULH/MULHSU/MULHU in EX is
// treated the same way (ctrl.late_res): its product is merged only at the
// EX/MEM flop, so it is not on the P1 bypass and is picked up from MEM.
//
// Outputs:
//   stall_id            : freeze the ID/EX register and tell if_stage's fetch
//                          queue not to pop its head.
//   flush_if / flush_id : on EX redirect, kill the two in-flight
//                          instructions ahead of the redirect target.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_res,    // ID/EX.ctrl.late_res (LOAD or MUL* in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD/MUL's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // EX has resolved a branch/jump
  // dmem bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the memory request is NOT
  // serviced this cycle. (imem backpressure is handled inside if_stage's
  // fetch queue.)
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // EX holds an in-flight DIV/DIVU/REM/REMU that has not finished yet
  // (ex_stage.div_stall). The instruction stays in ID/EX, PC holds, and
  // EX/MEM captures bubbles until the divider reports done.
  input  logic       div_stall,
  output logic       stall_id,          // ID/EX register holds (vs. bubble);
                                        // also tells if_stage's fetch queue
                                        // that the head is not consumed
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    // late_res already implies rd != 0 (folded in id_stage).
    load_use_hazard = id_ex_late_res
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // IF/ID combinational payload: NOP on redirect (wrong path). The
    // "no head present" NOP (imem stall, empty queue) is generated inside
    // if_stage; the PC hold lives in its accept logic.
    flush_if      = redirect;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    //   - div_stall   -> hold        (the divide stays in EX; redirect and
    //                                 load_use are both 0 while it does, so
    //                                 flush_id is unaffected)
    stall_id      = dmem_stall || load_use_hazard || div_stall;
    flush_id      = (load_use_hazard || redirect) && !dmem_stall;
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
