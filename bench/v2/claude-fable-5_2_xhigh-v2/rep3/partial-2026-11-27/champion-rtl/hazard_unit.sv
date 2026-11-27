// rtl/hazard_unit.sv
//
// Pipeline stall / bubble control.
//
// Load-use is the only data hazard the ID-stage operand bypass cannot
// cover: a LOAD in EX produces its data only in MEM, so an instruction
// immediately behind it that reads the LOAD's rd waits one cycle in ID
// (then takes the MEM bypass leg).
//
// The load-use comparator reads the RAW fetched word. A spurious match
// on an undelivered word is harmless: it becomes a bubble either way.
//
// Zero-bubble redirect: a redirect cycle is an ordinary fetch cycle. The
// fetch address is the redirect target (if_stage), so the word in IF is
// the TARGET instruction and it is captured into ID/EX like any other;
// nothing wrong-path is ever fetched and there is no kill. A LOAD or a
// DIV in EX never raises redirect, so load_use / ex_busy are mutually
// exclusive with it.
//
// ID/EX register control (id_stage):
//   dmem_stall                 -> hold     (a branch in EX re-asserts
//                                           the same redirect next cycle)
//   load_use                   -> bubble   (1-cycle load-use gap)
//   ex_busy                    -> hold     (DIV/REM waits in ID/EX)
//   imem_stall                 -> bubble   (no instruction delivered)
//   otherwise                  -> capture  (incl. the redirect target)
// expressed as  id_hold (clock-enable off) and id_bubble (synchronous
// clear, priority over the clock enable).
//
// `redirect_kill_en` (shipped build: raw instr[2] of the fetched word =
// AUIPC / JAL / JALR / LUI class; tied 0 when core.sv ZB_PC_LEG_LATE=1):
// the target word is not consumed in the redirect cycle (old 1-bubble
// behaviour), so the redirect-muxed pc stays out of the op_a operand
// path. `redirect` still reaches the ID/EX clear through one gate.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic [4:0] if_id_rs1,         // raw fetched instr[19:15]
  input  logic [4:0] if_id_rs2,         // raw fetched instr[24:20]
  input  logic       redirect,          // EX has resolved a branch/jump
  input  logic       redirect_kill_en,  // fallback: fetched word must not be
                                        // consumed in a redirect cycle
  // Bus backpressure. When low, the corresponding memory request is NOT
  // serviced this cycle.
  input  logic       imem_ready,
  // Fetch replay: a previously fetched word for the SEQUENTIAL fetch
  // address is in hand (if_stage / fetch_pred pw_q.hit, a flop). It
  // substitutes for the bus word when the bus stalls, except in a
  // redirect cycle (the fetch address is then the redirect target).
  input  logic       pw_hit,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up).
  input  logic       ex_mem_mem_op,
  // Multi-cycle DIV/REM in EX, divider not done yet (registers only).
  input  logic       ex_busy,
  output logic       stall_if,          // PC reg holds (valid when !redirect)
  output logic       stall_red,         // redirect cycle: target word not consumed
  output logic       id_hold,           // ID/EX register holds
  output logic       id_bubble,         // ID/EX ctrl/valid/rd cleared
  output logic       redirect_kill,     // redirect cycle: target word not consumed
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;
  logic early_bubble;

  always_comb begin
    load_use_hazard = id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    // fetch_ok = imem_ready | (pw_hit & !redirect)
    imem_stall = !imem_ready && (!pw_hit || redirect);
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason (redirect overrides in if_stage;
    // on a redirect only imem_stall / dmem_stall can be set).
    // stall_if is only used on the no-redirect path (pc_q advance, replay
    // register update), so it is computed for redirect = 0 and the late
    // `redirect` stays out of it. stall_red is the redirect-cycle
    // version (bus word only; load_use / ex_busy never coincide with a
    // redirect).
    stall_if     = load_use_hazard || !(imem_ready || pw_hit)
                || dmem_stall || ex_busy;
    stall_red    = !imem_ready || dmem_stall;

    // ID/EX. load_use and ex_busy are mutually exclusive (LOAD vs DIV in
    // EX), and neither a LOAD nor a DIV in EX raises redirect, so the
    // priority list in the header collapses to these two terms.
    id_hold      = dmem_stall || ex_busy;
    early_bubble = !dmem_stall && (load_use_hazard || (imem_stall && !ex_busy));
    redirect_kill = redirect_kill_en;
    id_bubble    = early_bubble
                || (redirect && redirect_kill_en && !dmem_stall);

    // EX/MEM register: holds on dmem_stall (LOAD/STORE waits in MEM until
    // the bus delivers).
    stall_ex_mem = dmem_stall;
    // MEM/WB register: on dmem_stall valid is cleared so the instruction
    // that just retired is not retired / written twice.
    hold_mem_wb  = dmem_stall;
  end

endmodule
