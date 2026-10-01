// rtl/forward_unit.sv
//
// ID-side forwarding compares for the raw instruction in ID (the
// instruction about to enter ID/EX) against the two producers ahead of it:
//   *_ex  : current ID/EX occupant (I-1) -> EX/MEM next cycle. Registered
//           in ID/EX; EX's only bypass (EX/MEM.alu_result) uses it. The
//           occupant's late EX reg_write clear (misaligned jump) is folded
//           in here, so EX needs no EX/MEM.reg_write qualifier.
//   *_mem : current EX/MEM occupant (I-2). Selects the MEM-stage producer
//           value in ID this cycle (ex_mem_fwd_ok already carries
//           reg_write && rd != 0 && !misaligned-mem-op).
// The MEM/WB occupant (I-3) is covered by the regfile write-first bypass.
// Exact because ID/EX only loads when EX/MEM and MEM/WB also advance
// (stall_id covers every dmem_stall and div_stall).
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via ID/EX + EX bypass.
module forward_unit (
  input  logic [4:0] rs1,
  input  logic [4:0] rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_en,
  input  logic       ex_wb_kill,       // EX clears the ID/EX occupant's reg_write
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_fwd_ok,
  output logic       fwd1_ex,
  output logic       fwd2_ex,
  output logic       fwd1_mem,
  output logic       fwd2_mem
);

  logic ex_ok;

  always_comb begin
    ex_ok    = id_ex_w_en && !ex_wb_kill && id_ex_rd != 5'b0;
    fwd1_ex  = ex_ok && id_ex_rd == rs1;
    fwd2_ex  = ex_ok && id_ex_rd == rs2;
    fwd1_mem = ex_mem_fwd_ok && ex_mem_rd == rs1;
    fwd2_mem = ex_mem_fwd_ok && ex_mem_rd == rs2;
  end

endmodule
