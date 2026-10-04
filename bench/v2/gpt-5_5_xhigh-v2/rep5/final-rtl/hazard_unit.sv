// rtl/hazard_unit.sv
//
// Hazards for the two-stage execute pipeline:
//   - A consumer in ID/EX cannot enter EX1 while its producer is still in
//     EX2, because EX1 latches operands before the EX2/MEM result exists.
//   - A consumer in ID/EX cannot enter EX1 while a matching LOAD is in
//     EX/MEM, because EX/MEM carries only the load address. The load data is
//     forwardable once registered in MEM/WB.
//   - Iterative DIV/REM and dmem stalls hold the execute payloads in place.
//
// Redirects kill the frontend plus the next EX1 payload. If an older dmem
// stall prevents the redirecting instruction from advancing to EX/MEM, EX1
// holds the redirecting instruction and the redirect replays until the hold
// clears.
module hazard_unit (
  input  logic       id_ex_valid,
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,
  input  logic [4:0] ex1_rd,
  input  logic       ex1_reg_write,
  input  logic       ex1_mem_read,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_reg_write,
  input  logic       ex_mem_mem_read,
  input  logic       redirect,
  // Bus backpressure (default-1 in zero-wait testbenches; VexRiscv-style
  // random ~22% stall in vex_main.cpp). When low, the corresponding
  // memory request is NOT serviced this cycle.
  input  logic       imem_ready,
  input  logic       dmem_ready,
  input  logic       ex_stage_stall,   // iterative EX op holds EX1/EX2
  // EX/MEM has a memory op in flight (the LOAD/STORE the dmem stall
  // would actually be holding up). Computed at top level from the
  // EX/MEM register's ctrl.mem_read | ctrl.mem_write.
  input  logic       ex_mem_mem_op,
  output logic       stall_if,          // PC reg holds unless redirect overrides
  output logic       stall_id,          // ID/EX register holds
  output logic       flush_if,          // IF/ID comb output -> NOP
  output logic       flush_id,          // ID/EX register captures '0
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb,       // MEM/WB clears valid only
  output logic       flush_ex1,         // EX1/EX2 register captures '0
  output logic       bubble_ex1         // EX1 bubble while ID/EX is held
);

  logic id_uses_ex1;
  logic id_uses_exmem_load;
  logic raw_hazard;
  logic imem_stall;
  logic dmem_stall;

  // ex1_mem_read is part of the visible hazard interface for debug and
  // future tuning. ex1_reg_write already covers load producers here.
  assign id_uses_ex1 = id_ex_valid
                    && ex1_reg_write
                    && (ex1_rd != 5'b0)
                    && ((ex1_rd == id_ex_rs1) || (ex1_rd == id_ex_rs2));

  assign id_uses_exmem_load = id_ex_valid
                            && ex_mem_reg_write
                            && ex_mem_mem_read
                            && (ex_mem_rd != 5'b0)
                            && ((ex_mem_rd == id_ex_rs1) || (ex_mem_rd == id_ex_rs2));

  assign raw_hazard = id_uses_ex1 || id_uses_exmem_load;
  assign imem_stall = !imem_ready;
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;

  // PC reg holds on any stall reason, but if_stage gives redirect higher
  // priority so a taken branch/jump is not lost under bus backpressure.
  assign stall_if = raw_hazard || imem_stall || dmem_stall || ex_stage_stall;

  // IF/ID combinational payload: NOP whenever we would otherwise see a
  // wrong-path instruction or no fetched instruction.
  assign flush_if = redirect || imem_stall;

  // ID/EX holds while the current instruction cannot safely enter EX1.
  // id_stage gives flush priority over stall, so redirect kills the held
  // younger payload even during unrelated interlocks.
  assign stall_id = raw_hazard || dmem_stall || ex_stage_stall;
  assign flush_id = redirect;

  // EX/MEM holds only for an actual dmem transaction waiting on the bus.
  assign stall_ex_mem = dmem_stall;

  // MEM/WB keeps its data fields alive during a dmem stall for forwarding,
  // while valid is cleared in mem_stage to avoid double retirement.
  assign hold_mem_wb = dmem_stall;

  // Kill the next EX1 payload on redirect. During dmem/divider holds the
  // ex_stage hold path takes priority, preserving the redirecting instr.
  assign flush_ex1 = redirect;

  // On a RAW interlock, let the current EX1 instruction advance when it can,
  // but keep ID/EX held and leave a bubble behind it.
  assign bubble_ex1 = raw_hazard && !redirect;

  // Keep lint quiet while preserving the explicit load-vs-ALU interface.
  /* verilator lint_off UNUSED */
  logic unused_ex1_mem_read;
  assign unused_ex1_mem_read = ex1_mem_read;
  /* verilator lint_on UNUSED */

endmodule
