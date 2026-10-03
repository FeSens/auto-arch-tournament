// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// The PC no longer freezes on these stalls: if_stage owns a 2-entry
// fetch-ahead FIFO whose accept term only looks at flops (count != 2) and the
// imem handshake. stall_id is fed back to if_stage as "ID does not consume the
// decode-source word", which decides whether a delivered word is passed on to
// ID or banked in the FIFO.
//
// Outputs:
//   stall_id            : ID/EX register holds (and ID does not consume).
//   flush_if / flush_id : on redirect (the registered EX/MEM redirect of the
//                          branch / jump now in MEM), kill the instruction
//                          in EX (wrong path, via EX) and the word in
//                          ID/IF ahead of the redirect target.
//   flush_if            : also masks the decode word to a NOP when no word is
//                          available to ID (queue empty and imem not ready).
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  // rs1/rs2 fields of the decode-source word (queue head, else the live imem
  // word; NOT NOP-substituted), so the late redirect does not feed the compare
  // below. When no word is available the compare may fire spuriously; that is
  // harmless: flush_id wins over stall_id for ctrl/valid (the slot becomes a
  // bubble either way) and nothing is pushed into the FIFO without a word.
  input  logic [4:0] if_id_rs1,         // decode-source word [19:15]
  input  logic [4:0] if_id_rs2,         // decode-source word [24:20]
  input  logic       redirect,          // EX/MEM flop: the op in MEM redirects
  // A word is available to ID this cycle (FIFO non-empty || imem delivers).
  input  logic       word_avail,
  // Data bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the memory request is NOT
  // serviced this cycle.
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // EX holds a multi-cycle M-op (MDU) whose result is not ready yet:
  // freeze ID/EX (hold, do not flush) while EX/MEM gets bubbles.
  input  logic       ex_busy,
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> NOP
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

    // IF/ID combinational payload: NOP whenever we wouldn't have a valid
    // instruction this cycle (redirect target unknown to IF, or neither the
    // FIFO nor imem has a word).
    flush_if      = redirect || !word_avail;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    //   - ex_busy     -> hold        (M-op stays in EX; never flushed)
    // ex_busy cannot coincide with load_use / redirect (the op in EX is
    // an M-op, not a load or branch), but it is gated off like dmem_stall
    // so a hold always wins over a bubble.
    // A missing word is a bubble into ID/EX through the NOP mask (flush_if)
    // and in.valid = 0, not through flush_id.
    stall_id      = dmem_stall || load_use_hazard || ex_busy;
    // redirect (a flop) never coincides with dmem_stall / ex_busy: the
    // redirecting op in MEM is neither a memory op nor an M-op.
    flush_id      = redirect || (load_use_hazard && !(dmem_stall || ex_busy));
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
