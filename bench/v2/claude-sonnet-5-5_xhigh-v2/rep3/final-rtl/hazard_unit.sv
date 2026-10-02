// rtl/hazard_unit.sv
//
// Detects the data hazard the end-of-ID forwarding network doesn't cover:
// a producer whose result is not final at the end of EX (`late_res`: a LOAD,
// whose data appears only in MEM, the JAL/JALR link and trap-qualified
// reg_write, and the DSP product of MUL*/MULH*). The instruction immediately
// behind that consumes the producer's rd and must be stalled by exactly one
// cycle; it then captures the value from the MEM-now forward term.
//
// Outputs:
//   stall_id : freeze the ID/EX register (and the fetch-queue head FD).
//   fd_pop   : the FD head is consumed (ID/EX captures it, or it is empty);
//              shifts the fetch queue. The PC does NOT stall any more: the
//              fetch queue absorbs the stall (its accept is flop-only).
//   flush_id : ID/EX captures a bubble: on EX redirect, load-use, or an
//              empty FD (the imem word has not arrived).
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_res,    // ID/EX.ctrl.late_res (late producer in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (its dest)
  input  logic [4:0] fd_rs1,            // FD.instr[19:15]     (next rs1)
  input  logic [4:0] fd_rs2,            // FD.instr[24:20]     (next rs2)
  input  logic       fd_valid,          // FD holds a (possibly wrong-path) word
  input  logic       redirect,          // EX has resolved a branch/jump
  // Bus backpressure (default-1 in zero-wait testbenches; random ~22% stall
  // in the evaluator). dmem: when low, the memory request is NOT serviced.
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // A multi-cycle divide is running in EX: hold ID/EX until the divider
  // finishes (EX/MEM takes bubbles meanwhile, see ex_stage).
  input  logic       ex_busy,
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       fd_pop,            // fetch-queue head consumed / empty
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    // Not qualified with fd_valid: with an empty FD, flush_id (below) already
    // bubbles ID/EX and fd_pop is 1 whatever stall_id says.
    load_use_hazard = id_ex_late_res
                   && (~|(id_ex_rd ^ fd_rs1) || ~|(id_ex_rd ^ fd_rs2))
                   && (id_ex_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - FD empty    -> bubble      (no instruction delivered)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    // ex_busy (divide in EX) holds ID/EX like a dmem stall; a divide is
    // never a redirecting instruction, so gating flush_id loses nothing.
    stall_id      = dmem_stall || load_use_hazard || ex_busy;
    fd_pop        = !stall_id || !fd_valid;
    flush_id      = (load_use_hazard || redirect || !fd_valid) && !dmem_stall && !ex_busy;
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
