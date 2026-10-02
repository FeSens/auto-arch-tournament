// rtl/forward_unit.sv
//
// Operand-fetch forwarding selects. For each rs of the instruction in OF
// (the D/O register), flags which in-flight producer(s) hold the freshest
// value. All compares are on flop-fed fields; the only late input is the
// EX instruction's post-trap reg_write (it depends on jalr_sum[1]).
//
//   fwd[0] dist 1: instruction in EX   (O/X register, result = x_result)
//   fwd[1] dist 2: instruction in MEM  (EX/MEM register, result = m_result)
//   fwd[2] dist 3: instruction in WB   (MEM/WB register, result = wb_data)
//
// The flags are NOT mutually exclusive: the consumer mux applies the
// priority dist 1 > dist 2 > dist 3 > D/O register value (regfile read,
// which covers everything older). x0 is never forwarded.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via the OF-stage muxes.
module forward_unit (
  input  logic [4:0] of_rs1,
  input  logic [4:0] of_rs2,
  input  logic [4:0] ex_rd,
  input  logic       ex_w_en,      // EX instr reg_write (post misalign trap)
  input  logic [4:0] mem_rd,
  input  logic       mem_w_en,     // MEM instr reg_write (post misalign trap)
  input  logic [4:0] wb_rd,
  input  logic       wb_w_en,      // MEM/WB reg_write (not valid: see hold_wb)
  output logic [2:0] fwd_rs1,
  output logic [2:0] fwd_rs2
);

  always_comb begin
    fwd_rs1[0] = ex_w_en  && ex_rd  != 5'b0 && ex_rd  == of_rs1;
    fwd_rs1[1] = mem_w_en && mem_rd != 5'b0 && mem_rd == of_rs1;
    fwd_rs1[2] = wb_w_en  && wb_rd  != 5'b0 && wb_rd  == of_rs1;

    fwd_rs2[0] = ex_w_en  && ex_rd  != 5'b0 && ex_rd  == of_rs2;
    fwd_rs2[1] = mem_w_en && mem_rd != 5'b0 && mem_rd == of_rs2;
    fwd_rs2[2] = wb_w_en  && wb_rd  != 5'b0 && wb_rd  == of_rs2;
  end

endmodule
