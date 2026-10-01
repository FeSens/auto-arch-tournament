// rtl/hazard_unit.sv
//
// Detects the only data hazard the textbook 5-stage doesn't cover via
// forwarding: load-use. A LOAD in EX produces its data only after MEM,
// so an instruction immediately behind that consumes the LOAD's rd
// must be stalled by exactly one cycle.
//
// Outputs:
//   stall_if / stall_id : freeze the PC reg and the ID/EX register as needed.
//   flush_if / flush_id : mark fetched payload invalid on bus/divider stalls,
//                          and inject ID/EX bubbles for hazards/redirects.
//   flush_id            : also kills ID's own register on load-use to
//                          inject a single-cycle bubble between LOAD
//                          and the dependent instruction.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_mem_read,    // ID/EX.ctrl.mem_read (LOAD in EX)
  input  logic [4:0] id_ex_rd,          // ID/EX.rd            (LOAD's dest)
  input  logic       id_ex_reg_write,
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       if_id_valid,
  input  logic       if_id_is_branch,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_reg_write,
  input  logic       ex_mem_mem_read,
  input  logic       redirect,          // EX has resolved a branch/jump
  input  logic       ex_div_busy,       // divider holds the instruction in EX
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_if,          // IF/ID payload valid=0
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb,       // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
  output logic       branch_stall
);

  logic load_use_hazard;
  logic imem_stall;
  logic dmem_stall;
  logic branch_dep_ex;
  logic branch_dep_load;

  always_comb begin
    load_use_hazard = if_id_valid && id_ex_mem_read
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    branch_dep_ex = if_id_valid && if_id_is_branch && id_ex_reg_write
                  && (id_ex_rd != 5'b0)
                  && ((id_ex_rd == if_id_rs1) || (id_ex_rd == if_id_rs2));
    branch_dep_load = if_id_valid && if_id_is_branch && ex_mem_mem_read
                    && ex_mem_reg_write && (ex_mem_rd != 5'b0)
                    && ((ex_mem_rd == if_id_rs1) || (ex_mem_rd == if_id_rs2));
    branch_stall = branch_dep_ex || branch_dep_load;
    imem_stall = !imem_ready;
    // dmem stall only matters if there's actually a memory op in EX/MEM
    // — otherwise bus-not-ready is irrelevant to the pipeline.
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // PC reg holds on any stall reason.
    stall_if      = load_use_hazard || branch_stall || imem_stall || dmem_stall || ex_div_busy;
    // Fetch/divider stalls invalidate the IF payload without changing its
    // instruction bits. ID uses validity to suppress all effects.
    flush_if      = imem_stall || ex_div_busy;
    // ID/EX register:
    //   - dmem_stall  -> hold        (preserve in-flight pipeline state)
    //   - load_use    -> bubble      (1-cycle stall between LOAD + use)
    //   - redirect    -> bubble      (kill wrong-path)
    //   - otherwise   -> capture
    // dmem_stall takes precedence over load_use's bubble: re-evaluate
    // load_use next cycle when the bus unblocks. flush_id is 1 only when
    // we want bubble (not hold).
    stall_id      = dmem_stall || load_use_hazard || ex_div_busy;
    flush_id      = (load_use_hazard || branch_stall || redirect) && !dmem_stall && !ex_div_busy;
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
