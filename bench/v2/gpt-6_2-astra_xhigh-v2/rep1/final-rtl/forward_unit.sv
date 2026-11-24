// rtl/forward_unit.sv
//
// Compare tags alongside the register-file read in ID. When the consumer
// reaches EX, the two producers have advanced to EX/MEM and MEM/WB.
module forward_unit (
  input  logic       clock,
  input  logic       stall_id,
  input  logic       capture_replay,
  input  logic       late_rs1,
  input  logic       late_rs2,
  input  logic [4:0] if_id_rs1,
  input  logic [4:0] if_id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_writes,
  input  logic       mem_writes,
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  function automatic logic [2:0] source_select(input logic [4:0] src);
    logic from_ex, from_mem;
    from_ex  = ex_writes && id_ex_rd != 0 && src == id_ex_rd;
    from_mem = mem_writes && ex_mem_rd != 0 && src == ex_mem_rd;
    source_select = {!(from_ex || from_mem), from_mem && !from_ex, from_ex};
  endfunction

  always_ff @(posedge clock) begin
    if (capture_replay) begin
      fwd_rs1 <= {!late_rs1, late_rs1, 1'b0};
      fwd_rs2 <= {!late_rs2, late_rs2, 1'b0};
    end else if (!stall_id) begin
      fwd_rs1 <= source_select(if_id_rs1);
      fwd_rs2 <= source_select(if_id_rs2);
    end
  end

endmodule
