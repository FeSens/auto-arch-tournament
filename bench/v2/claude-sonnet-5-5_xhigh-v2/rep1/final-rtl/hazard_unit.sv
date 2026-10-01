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
//   flush_if            : imem bus stall -> NOP into ID.
//   flush_id            : on EX redirect, kills the wrong-path instruction
//                          in IF/ID by bubbling the ID/EX register; also
//                          kills ID's own register on load-use to inject a
//                          single-cycle bubble between LOAD and the
//                          dependent instruction.
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
  // Sub-word load (LB/LBU/LH/LHU) in MEM: EX/MEM.ctrl.mem_to_reg &&
  // mem_width != word. ID only bypasses the raw dmem word (LW), so a consumer
  // of a sub-word load waits until the load is in WB (regfile write-first).
  input  logic       ex_mem_sub_ld,
  input  logic [4:0] ex_mem_rd,         // EX/MEM.rd (the load in MEM's dest)
  // MUL/DIV/REM in EX whose multi-cycle result is not ready yet
  // (a function of flops only: ID/EX.alu_op decode + muldiv done).
  input  logic       md_stall,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> NOP (imem stall)
  output logic       flush_id,          // ID/EX register captures a bubble
                                        // (valid + ctrl cleared)
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    // (1) classic load-use: a load in EX, consumer in ID (one bubble; the
    //     LW then bypasses its raw word from MEM).
    // (2) sub-word load in MEM, consumer in ID: no align bypass exists, so
    //     bubble once more; next cycle the load is in WB (EX/MEM now holds the
    //     bubble / younger op, so this term cannot re-fire for the same load)
    //     and ID reads it through the regfile write-first path. Uses only
    //     EX/MEM flops and ignores the MEM misalign trap (a superset: an
    //     unneeded bubble on a trapping LH is harmless). id_stage relies on
    //     this being a superset of its sub-word-load bypass miss.
    load_use_hazard = (id_ex_mem_read
                       && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                       && (id_ex_rd != 5'b0))
                   || (ex_mem_sub_ld
                       && (ex_mem_rd == if_id_rs1 || ex_mem_rd == if_id_rs2)
                       && (ex_mem_rd != 5'b0));
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    stall_if      = load_use_hazard || imem_stall || dmem_stall || md_stall;
    // IF/ID combinational payload: NOP only when imem didn't deliver.
    // `redirect` is NOT here on purpose (it would sit in front of the
    // regfile read address / decoder / load-use compare). The wrong-path
    // instruction in IF/ID during a redirect cycle is dropped by flush_id
    // at the ID/EX register.
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    //   - md_stall    -> hold        (MUL/DIV stays in EX; the younger
    //                                 instruction is re-fetched/held exactly
    //                                 as for a dmem stall)
    stall_id      = dmem_stall || load_use_hazard || md_stall;
    // The classic load-use term needs a LOAD in EX and md_stall needs a
    // MUL/DIV in EX, so those are mutually exclusive. The sub-word-load term
    // (load in MEM) may overlap md_stall: then ID/EX holds (stall_id) and no
    // bubble is injected (flush_id is masked), which is safe because EX/MEM
    // takes a bubble at the end of this cycle, so the load is in WB (and the
    // term is gone) by the time the MUL/DIV completes. `redirect` is the
    // registered MEM-stage redirect (EX/MEM.redir): the instruction in EX
    // behind it is squashed by ex_stage (so md_stall is never raised
    // alongside it) and this bubble kills the one now in IF/ID. Under a
    // dmem stall (a falsely predicted load/store held in MEM) the bubble
    // waits for the release cycle, where redir is still set.
    flush_id      = (load_use_hazard || redirect) && !dmem_stall && !md_stall;
    flush_if      = imem_stall;
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
