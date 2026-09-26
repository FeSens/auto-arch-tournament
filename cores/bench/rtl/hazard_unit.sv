// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if            : freeze the PC reg.
//   hold_id             : freeze the whole ID/EX register (dmem stall,
//                          divide in EX). Load-use is not in it: its
//                          bubble comes from flush_id alone.
//   flush_if / flush_id : on EX redirect, kill the two in-flight
//                          instructions ahead of the redirect target.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction. It clears
//                          only ID/EX's side-effect control bits (see
//                          id_stage.sv), so this late net fans out to a
//                          handful of flops instead of the whole
//                          register's enable.
//
// dmem stall: the EX/MEM memory op cannot complete this cycle
// (!mem_ready). mem_stage raises mem_ready when the bus serves the op,
// and also on a refused bus cycle for a load that hits its stall-only
// cache or a store it posts, so only those misses stall.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       redirect,          // EX has resolved a branch/jump
  // Effective fetch-ready from IF: the external imem accepted the fetch,
  // or IF's replay store supplied the word for the current PC. When low,
  // IF has no instruction this cycle.
  input  logic       fetch_ready,
  // The MEM-stage memory op completes this cycle (mem_stage): the dmem
  // bus served it, or, on a refused cycle (VexRiscv-style random ~22%
  // stall in cosim), the load hit mem_stage's stall-only cache or the
  // store was posted to its store buffer. When low, the op waits. Tied
  // to 1 when io_dmemReady is (zero-wait testbenches, FPGA bench).
  input  logic       mem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // A DIV/DIVU/REM/REMU occupies EX and its div_unit result is not ready
  // yet. EX feeds bubbles into EX/MEM itself; here we only hold the
  // younger instructions (PC + ID/EX). A divide is never a load and never
  // redirects, so load_use / redirect are both 0 while this is high.
  input  logic       ex_div_busy,
  output logic       stall_if,          // PC reg holds
  output logic       hold_id,           // ID/EX register holds (all of it)
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX control bits clear (bubble)
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
    // A replayed word counts as a delivered fetch: load-use detection
    // above sees its rs1/rs2 and the PC advances exactly as on a live one.
    imem_stall = !fetch_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !mem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    stall_if      = load_use_hazard || imem_stall || dmem_stall || ex_div_busy;
    // IF/ID combinational payload: NOP whenever we wouldn't have a valid
    // instruction this cycle (redirect target unknown to IF, or neither
    // imem nor the replay store delivered).
    flush_if      = redirect || imem_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - ex_div_busy -> hold        (divide still iterating in EX)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold). load_use needs no hold term: without
    // dmem_stall it already raises flush_id (the payload the bubble
    // captures is inert, and the PC hold re-presents the instruction),
    // and with dmem_stall it is covered by hold_id. A divide in EX is
    // never a load and never redirects, so flush_id and ex_div_busy are
    // never high together.
    hold_id       = dmem_stall || ex_div_busy;
    flush_id      = (load_use_hazard || redirect) && !dmem_stall;
    // EX/MEM register: holds on dmem_stall (the LOAD/STORE waits in MEM
    // until it can complete).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall the previously-retired instruction's
    // data fields stay alive for forwarding (e.g. a held BNE needs the
    // LOAD's load_data via fwd_mem_wb), but valid is cleared so we don't
    // double-retire / double-write the regfile.
    hold_mem_wb   = dmem_stall;
  end

endmodule
