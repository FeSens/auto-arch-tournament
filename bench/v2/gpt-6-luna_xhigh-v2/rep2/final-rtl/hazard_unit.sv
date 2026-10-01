// Stall and flush control for the ID -> operand -> execute pipeline.
// The operand register must wait when its source is still in execute, and
// a load remains unavailable for one more cycle while crossing MEM/WB.
module hazard_unit (
  input  logic       id_ex_valid,
  input  logic [4:0] id_ex_rs1,
  input  logic [4:0] id_ex_rs2,
  input  logic       op_ex_valid,
  input  logic       op_ex_reg_write,
  input  logic [4:0] op_ex_rd,
  input  logic       ex_mem_mem_read,
  input  logic [4:0] ex_mem_rd,
  input  logic       redirect,
  input  logic       execute_hold,
  input  logic       imem_ready,
  input  logic       dmem_ready,
  input  logic       ex_mem_mem_op,
  output logic       stall_if,
  output logic       stall_id,
  output logic       flush_if,
  output logic       flush_id,
  output logic       stall_operand,
  output logic       flush_operand,
  output logic       stall_ex_mem,
  output logic       hold_mem_wb
);

  logic id_uses_op_result;
  logic id_waits_for_load;
  logic imem_stall;
  logic dmem_stall;

  always_comb begin
    id_uses_op_result = id_ex_valid && op_ex_valid && op_ex_reg_write &&
                        (op_ex_rd != 5'b0) &&
                        ((op_ex_rd == id_ex_rs1) || (op_ex_rd == id_ex_rs2));
    id_waits_for_load = id_ex_valid && ex_mem_mem_read &&
                        (ex_mem_rd != 5'b0) &&
                        ((ex_mem_rd == id_ex_rs1) || (ex_mem_rd == id_ex_rs2));
    imem_stall = !imem_ready;
    dmem_stall = !dmem_ready && ex_mem_mem_op;

    // An execute-stage producer is not registered until this edge, so
    // hold its dependent instruction in ID for one cycle. Loads then need
    // one additional cycle until their value is present in MEM/WB.
    stall_if      = id_uses_op_result || id_waits_for_load || imem_stall ||
                    dmem_stall || execute_hold;
    stall_id      = id_uses_op_result || id_waits_for_load || dmem_stall ||
                    execute_hold;
    flush_if      = redirect || imem_stall;
    flush_id      = redirect;

    // During a data bus stall or iterative divide, preserve the current
    // operand payload. A dependency bubble or redirect flushes that slot.
    stall_operand = dmem_stall || execute_hold;
    flush_operand = redirect || id_uses_op_result || id_waits_for_load;
    stall_ex_mem  = dmem_stall;
    hold_mem_wb   = dmem_stall;
  end

endmodule
