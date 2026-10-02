// rtl/fwd_select.sv
//
// ID-stage operand-forward select decode. For one source register `a` of
// the instruction being captured into ID/EX this cycle, compares against
// the three producers in flight and returns the selects for the operand
// network that id_stage registers:
//
//   sel_ex      : producer now in EX   -> this cycle's EX result (late term)
//   sel_mem_ld  : producer now in MEM, a load -> load_data (dmem read + align)
//   sel_mem_alu : producer now in MEM, other  -> EX/MEM.alu_result | mul_q
//   sel_wb      : producer now in WB   -> wb_w_data (the regfile read this
//                                         cycle does not see its write)
//   sel_ram     : none of the above    -> regfile read (x0 reads 0)
//
// The EX term has NO priority masking on the others: sel_mem_ld/alu/wb/ram
// are one-hot among themselves (youngest of MEM / WB / regfile wins) and do
// not contain !sel_ex; id_stage ends with a single `sel_ex ? ex_val : rest`
// 2:1 mux, so the late EX result sees one LUT and the compare ->
// fanout-32 select leg has no mask level in front of it.
//
// ex_we is the EX producer's forwardable-write flag, registered in ID/EX
// (reg_write && !late_res && rd != 0): a late producer (load, JAL/JALR, MUL*)
// stalls its immediate consumer in the hazard unit, so ID never forwards from
// it in EX, and rd != 0 is folded in so the EX compare needs no `a != 0`.
// mem_we is the MEM producer's reg_write (the misaligned-access trap is
// already applied in EX).
//
// The register-number compares are written as XOR / OR reductions (not `==`)
// so synthesis builds them from plain LUTs rather than carry-chain cells.
//
// Latency:        combinational.
// RVFI fields:    n/a (feeds the operand network that produces rs?_rdata).
module fwd_select (
  input  logic [4:0] a,
  input  logic [4:0] ex_rd,
  input  logic       ex_we,
  input  logic [4:0] mem_rd,
  input  logic       mem_we,
  input  logic       mem_is_load,
  input  logic [4:0] wb_rd,
  input  logic       wb_we,
  output logic       sel_ex,
  output logic       sel_mem_ld,
  output logic       sel_mem_alu,
  output logic       sel_wb,
  output logic       sel_ram
);

  logic nz;
  logic m_mem;
  logic m_wb;

  always_comb begin
    nz    = (a != 5'b0);
    sel_ex = ex_we && ~|(ex_rd ^ a);
    m_mem = nz && mem_we && ~|(mem_rd ^ a);
    m_wb  = nz && wb_we  && ~|(wb_rd  ^ a);

    sel_mem_ld  = m_mem && mem_is_load;
    sel_mem_alu = m_mem && !mem_is_load;
    sel_wb      = !m_mem && m_wb;
    sel_ram     = !m_mem && !m_wb;   // x0: regfile reads 0
  end

endmodule
