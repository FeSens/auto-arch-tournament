// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if            : the backend cannot consume the IF/ID head word
//                          this cycle. The fetch stage keeps fetching into
//                          its prefetch FIFO while this is high; an imem
//                          stall is handled entirely inside if_stage (it
//                          hands over a NOP/valid=0 bubble when it has
//                          nothing) and is no longer a stall reason here.
//   stall_id            : ID/EX register holds.
//   flush_id            : on EX redirect, kill the wrong-path instruction
//                          in ID; also kills ID's own register on load-use
//                          to inject a single-cycle bubble between LOAD
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
  // dmem bus backpressure (default-1 in zero-wait testbenches; random
  // ~22% stall in the bench). When low, the memory request is NOT
  // serviced this cycle.
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // EX holds a multi-cycle M op whose result is not ready yet. ID/EX
  // holds (no flush); ex_stage itself puts a bubble into EX/MEM.
  input  logic       ex_busy,
  output logic       stall_if,          // backend does not consume IF/ID
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic dmem_stall;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // The IF/ID head word is not consumed on any backend stall reason.
    // (imem not ready is NOT a reason: if_stage emits a bubble itself.)
    stall_if      = load_use_hazard || dmem_stall || ex_busy;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    //   - ex_busy     -> hold        (M op still computing in EX; an M op
    //                                 never redirects and never loads, so
    //                                 flush_id is 0 while ex_busy)
    stall_id      = dmem_stall || load_use_hazard || ex_busy;
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
