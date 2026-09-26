// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Except a conditional BRANCH: it enters EX without the stall as a
// "late branch" (late_br). EX treats it as inert and MEM resolves it
// against the LOAD's registered MEM/WB.read_data, redirecting one cycle
// later from a WB-stage flop (late_kill, see mem_stage.sv).
//
// A JALR directly behind a late branch takes a one-cycle stall instead
// (late_jalr). Without it the JALR would be in EX while the late branch
// is in MEM; if the branch then mispredicts, that wrong-path JALR has
// already redirected fetch to an arbitrary register value for a cycle,
// which puts an unbounded address on the imem bus. With the stall it
// reaches EX only once the late branch is in WB, where late_kill
// overrides its redirect. Pc-relative wrong-path targets are always
// real code.
//
// Outputs:
//   stall_if            : freeze the PC reg.
//   hold_id             : freeze the whole ID/EX register (dmem stall,
//                          divide in EX). Load-use is not in it: its
//                          bubble comes from flush_id alone.
//   flush_if / flush_id : on a redirect (EX, or late_kill from WB), kill
//                          the in-flight instructions behind it.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction. It clears
//                          only ID/EX's side-effect control bits (see
//                          id_stage.sv), so this late net fans out to a
//                          handful of flops instead of the whole
//                          register's enable.
//   late_br             : ID/EX captures the IF/ID BRANCH as late. Which
//                          operand is the LOAD's rd is taken later, in
//                          EX, from the forward unit's EX/MEM match, so
//                          these compares fan out no further.
//
// dmem stall: the EX/MEM memory op cannot complete this cycle
// (!mem_ready). mem_stage raises mem_ready when the bus serves the op,
// and also on a refused bus cycle for a load that hits its stall-only
// cache or a store it posts, so only those misses stall. On a late_kill
// cycle the EX/MEM op is wrong-path and dropped, so it never stalls.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  // ID/EX.ld_nz: LOAD in EX with rd != x0, registered in ID so the
  // final load-use gate stays narrow.
  input  logic       id_ex_ld_nz,
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic       id_ex_late,        // ID/EX holds a late branch
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       if_id_is_branch,   // IF predecode: BRANCH (valid funct3)
  input  logic       if_id_is_jalr,     // IF predecode: JALR opcode
  // EX redirect (mispredict / JALR) or late_kill, merged in ex_stage.
  input  logic       redirect,
  // Late-branch mispredict in WB (registered in MEM). Drops the MEM-stage
  // op; the kill itself reaches IF/ID through `redirect`.
  input  logic       late_kill,
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
  // redirects, so load_use and an EX redirect are 0 while this is high;
  // late_kill can be (the divide is then wrong-path).
  input  logic       ex_div_busy,
  output logic       stall_if,          // PC reg holds
  output logic       hold_id,           // ID/EX register holds (all of it)
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX control bits clear (bubble)
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb,       // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
  output logic       late_br            // capture the IF/ID BRANCH as late
);

  logic ld_rs1;
  logic ld_rs2;
  logic ld_dep;
  logic late_jalr;
  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    ld_rs1    = (id_ex_rd == if_id_rs1);
    ld_rs2    = (id_ex_rd == if_id_rs2);
    ld_dep    = id_ex_ld_nz && (ld_rs1 || ld_rs2);
    late_br   = ld_dep && if_id_is_branch;
    late_jalr = id_ex_late && if_id_is_jalr;
    load_use_hazard = (ld_dep && !if_id_is_branch) || late_jalr;
    // A replayed word counts as a delivered fetch: load-use detection
    // above sees its rs1/rs2 and the PC advances exactly as on a live one.
    imem_stall = !fetch_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline. A
    // late-killed op is not waited for.
    dmem_stall = !mem_ready && ex_mem_mem_op && !late_kill;

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
    // and with dmem_stall it is covered by hold_id. flush_id and
    // ex_div_busy are high together only on a late_kill: the control
    // half's clear wins over the hold (id_stage.sv), which kills the
    // wrong-path divide in EX (div_unit takes the same kill).
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
