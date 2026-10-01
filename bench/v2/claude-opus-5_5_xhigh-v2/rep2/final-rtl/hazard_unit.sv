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
//   flush_if            : imem stall, the IF word is invalid.
//   flush_id            : kills ID's own register on load-use to inject
//                          a single-cycle bubble between a LOAD / MUL* /
//                          DIV* and the dependent instruction.
// The EX redirect is not an input: the wrong-path word is captured and
// killed in EX (ID/EX.squash).
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  // ID/EX.late: LOAD / MUL* / DIV* in EX (result only 2-ahead, from
  // MEM). Registered, cleared for a squashed wrong-path word.
  input  logic       id_ex_late,
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (its dest)
  // Raw fetch-word rs fields (io_imemData), not gated by imem stall. A
  // spurious hit from a garbage word during an imem stall only raises
  // stall_if (already high) and bubbles ID/EX (bubbled anyway on !valid).
  input  logic [4:0] if_id_rs1,         // fetch word [19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // fetch word [24:20]  (next rs2)
  // Fetch-store word rs fields (fword_q, a flop). The IF word is the
  // store word when use_store (flops), else the bus word; the two
  // compares run in parallel and use_store picks the 1-bit result.
  input  logic [4:0] fs_rs1,
  input  logic [4:0] fs_rs2,
  input  logic       use_store,
  // IF word valid: bus delivered or the fetch store hit (flops only).
  input  logic       fetch_ok,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  // A DIV* is in EX and the sequential divider has not finished. IF and
  // ID/EX hold (no flush) until the result is ready; EX/MEM takes
  // bubbles meanwhile (ex_stage). Comes from flops only.
  input  logic       div_busy,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID comb output -> invalid
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only
                                        // (data fields stay)
);

  logic load_use_hazard;
  logic lu_bus, lu_fs;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    lu_bus = (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2);
    lu_fs  = (id_ex_rd == fs_rs1    || id_ex_rd == fs_rs2);
    load_use_hazard = id_ex_late
                   && (use_store ? lu_fs : lu_bus)
                   && (id_ex_rd != 5'b0);
    imem_stall = !fetch_ok;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason (a redirect overrides it in IF).
    stall_if      = load_use_hazard || imem_stall || dmem_stall || div_busy;
    // IF/ID combinational payload: invalid when imem didn't deliver. The
    // wrong-path word behind a redirect is killed in EX (ID/EX.squash).
    flush_if      = imem_stall;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - div_busy    -> hold        (divide waits in EX for its result;
    //                                 a consumer behind it would raise
    //                                 load_use, which must not clear it)
    //   - load_use    -> bubble      (1-cycle stall between a LOAD /
    //                                 MUL* / DIV* and its consumer)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    stall_id      = dmem_stall || load_use_hazard || div_busy;
    flush_id      = load_use_hazard && !dmem_stall && !div_busy;
    // EX/MEM register: holds on dmem_stall (LOAD waits in MEM until the
    // bus delivers).
    stall_ex_mem  = dmem_stall;
    // MEM/WB register: on dmem_stall valid is cleared so we don't
    // double-retire / double-write the regfile (data fields are kept;
    // nothing forwards from MEM/WB, operands are captured in ID).
    hold_mem_wb   = dmem_stall;
  end

endmodule
