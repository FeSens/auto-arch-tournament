// rtl/forward_unit.sv
//
// ID-stage bypass-select generator. For each source of the instruction
// being decoded (IF instr rs1/rs2), picks the youngest in-flight producer:
//   ex  : ID/EX  (its EX result, ex_result, is final on every ID/EX
//                 capture edge; a LOAD or MUL* in EX never gets here
//                 because the load/mul-use interlock bubbles)
//   mem : EX/MEM (load_data at the last mux level, or alu_or_mul)
//   wb  : MEM/WB (wb_w_data, the value being written this edge; replaces
//                 the regfile write-first bypass)
//   rf  : none of the above -> regfile read.
// Each producer's write enable is trap-cleared (misaligned JAL/JALR in
// EX, misaligned load in MEM) and rd != 0 is required. Priority is
// ex > mem > wb > rf; sel_mem/sel_wb are not masked by the higher
// selects, the mux in id_stage applies the priority (ex at the last
// level).
//
// The ID forward is exact because ID/EX only captures when EX/MEM and
// MEM/WB also advance (!dmem_stall && !ex_busy && !load_use), i.e. on a
// cycle where every older producer holds its final value.
//
// Latency:        combinational.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via ID/EX.
module forward_unit (
  input  logic [4:0] rs1,          // decoding instruction's rs1 (IF instr)
  input  logic [4:0] rs2,
  input  logic [4:0] ex_rd,        // ID/EX.rd
  input  logic       ex_w_en,      // ID/EX reg_write (trap-cleared)
  input  logic [4:0] mem_rd,       // EX/MEM.rd
  input  logic       mem_w_en,     // EX/MEM reg_write (trap-cleared)
  input  logic [4:0] wb_rd,        // MEM/WB.rd
  input  logic       wb_w_en,      // MEM/WB reg_write && valid
  output logic       sel1_ex,
  output logic       sel1_mem,
  output logic       sel1_wb,
  output logic       sel2_ex,
  output logic       sel2_mem,
  output logic       sel2_wb
);

  logic ex_nz, mem_nz, wb_nz;

  always_comb begin
    ex_nz  = ex_rd  != 5'b0;
    mem_nz = mem_rd != 5'b0;
    wb_nz  = wb_rd  != 5'b0;
    sel1_ex  = ex_w_en  && ex_nz  && (ex_rd  == rs1);
    sel2_ex  = ex_w_en  && ex_nz  && (ex_rd  == rs2);
    sel1_mem = mem_w_en && mem_nz && (mem_rd == rs1);
    sel2_mem = mem_w_en && mem_nz && (mem_rd == rs2);
    sel1_wb  = wb_w_en  && wb_nz  && (wb_rd  == rs1);
    sel2_wb  = wb_w_en  && wb_nz  && (wb_rd  == rs2);
  end

endmodule
