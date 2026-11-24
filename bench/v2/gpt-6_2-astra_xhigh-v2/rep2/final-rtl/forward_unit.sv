// rtl/forward_unit.sv
//
// Operand forwarding. For each rs in the EX-stage's source list, picks
// where the freshest value lives:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the in-flight ALU result from the EX/MEM register
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Compare the incoming ID sources while both producers are a stage earlier.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       stall_id,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_reg_write,
  input  logic       ex_mem_forwardable,
  output logic       younger_rs1_match,
  output logic       older_rs1_match,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  logic younger_rs1_q, younger_rs2_q, older_rs1_q, older_rs2_q;
  logic older_writer;
  assign younger_rs1_match = id_ex_rd != 0 && id_ex_rd == id_rs1;
  assign older_writer = ex_mem_reg_write && ex_mem_rd != 0;
  assign older_rs1_match = older_writer && ex_mem_rd == id_rs1;

  always_ff @(posedge clock) begin
    if (!stall_id) begin
      younger_rs1_q <= younger_rs1_match;
      younger_rs2_q <= id_ex_rd != 0 && id_ex_rd == id_rs2;
      older_rs1_q   <= older_rs1_match;
      older_rs2_q   <= older_writer && ex_mem_rd == id_rs2;
    end
  end

  // EX has now resolved traps on the younger producer. A suppressed
  // writer leaves the older match eligible, even if WB already retired.
  assign fwd_rs1[0] = younger_rs1_q && ex_mem_forwardable;
  assign fwd_rs2[0] = younger_rs2_q && ex_mem_forwardable;
  assign fwd_rs1[1] = older_rs1_q && !fwd_rs1[0];
  assign fwd_rs2[1] = older_rs2_q && !fwd_rs2[0];
endmodule
