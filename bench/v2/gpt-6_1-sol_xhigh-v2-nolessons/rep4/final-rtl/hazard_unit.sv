// OC holds decode when its sources or the occupied EX slot cannot advance.
// An unavailable EX load moves to MEM while OC inserts exactly one bubble.
module hazard_unit (
  input logic oc_valid,
  input logic operands_ready,
  input logic redirect,
  input logic divider_wait,
  input logic imem_ready,
  input logic dmem_ready,
  input logic ex_mem_mem_op,
  output logic stall_if, stall_id, flush_if, flush_id,
  output logic stall_ex_mem, hold_mem_wb, hold_oc_ex
);
  logic dmem_stall;
  assign dmem_stall = !dmem_ready && ex_mem_mem_op;
  assign stall_ex_mem = dmem_stall;
  assign hold_mem_wb = dmem_stall;
  assign hold_oc_ex = dmem_stall || divider_wait;
  always_comb begin
    stall_id = oc_valid && (hold_oc_ex || !operands_ready);
    stall_if = stall_id || !imem_ready;
    flush_if = !imem_ready;
    flush_id = 1'b0;
    if (redirect) begin
      stall_id = 1'b0;
      stall_if = 1'b0;
      flush_if = 1'b1;
      flush_id = 1'b1;
    end
  end
endmodule
