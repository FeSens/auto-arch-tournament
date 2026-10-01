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
//   flush_if            : imem did not deliver -> NOP/valid=0 into ID.
//                          (A redirect does not touch the IF payload: the
//                          PC takes the redirect target over any stall and
//                          ID/EX is bubbled by flush_id.)
//   flush_id            : on the registered redirect (redirect_q, one
//                          cycle after EX resolved; the branch is in
//                          EX/MEM), kill the second wrong-path instruction
//                          about to enter ID/EX. ex_stage squashes the
//                          first one (in EX) itself. EX/MEM then holds the
//                          branch (no memory op), so dmem_stall is 0.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  // Raw fetch word rs1/rs2 (io_imemData[19:15]/[24:20]), NOT the
  // flush-muxed IF/ID instr: on imem stall or redirect the PC already
  // holds/redirects and ID/EX gets a bubble either way, so a spurious
  // compare there is harmless and the redirect -> NOP-mux -> compare ->
  // stall/flush chain is off the critical path.
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic       redirect,          // registered redirect (redirect_q)
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // EX holds an M-extension op whose multi-cycle muldiv result is not
  // ready yet. PC and ID/EX hold (not a bubble); ex_stage itself injects
  // the bubble into EX/MEM so older instructions keep draining.
  input  logic       m_stall,
  output logic       stall_if,         // PC reg holds
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
    stall_if      = load_use_hazard || imem_stall || dmem_stall || m_stall;
    // IF/ID combinational payload: NOP whenever imem didn't deliver.
    flush_if      = imem_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    //   - m_stall     -> hold        (M-op waits in EX for muldiv)
    // m_stall never needs to gate flush_id: an M-op in EX is neither a
    // LOAD (no load_use) nor a branch/jump (no redirect).
    stall_id      = dmem_stall || load_use_hazard || m_stall;
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
