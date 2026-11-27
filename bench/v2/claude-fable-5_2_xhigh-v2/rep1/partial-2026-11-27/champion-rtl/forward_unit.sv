// rtl/forward_unit.sv
//
// Operand forwarding selects, computed one stage EARLY (in ID) and
// registered together with ID/EX, so the EX-stage operand muxes are driven
// straight from flops instead of sitting behind two 5-bit comparators.
//
// For the instruction in ID, compare its rs1/rs2 against
//   - the rd of the instruction currently in EX  (ID/EX register):
//       next cycle that instruction sits in EX/MEM  -> select 01
//   - the rd of the instruction currently in MEM (EX/MEM register):
//       next cycle that instruction sits in MEM/WB  -> select 10
//   - otherwise                                     -> select 00
//       (ID/EX rs?_val = regfile read, incl. the write-first bypass of the
//        instruction currently in WB)
//
// This is equivalent to comparing in EX because ID/EX only captures when
// !stall_id, and on that edge EX/MEM and MEM/WB both advance by exactly
// one instruction. The writer enables are the post-trap reg_write bits of
// the EX and MEM stages (a misaligned JAL/JALR or load does not write).
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Latency:        combinational (registered by id_stage).
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] ex_rd,       // ID/EX.rd
  input  logic       ex_w_en,     // EX-stage post-trap reg_write
  input  logic [4:0] mem_rd,      // EX/MEM.rd
  input  logic       mem_w_en,    // MEM-stage post-trap reg_write
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (ex_w_en  && ex_rd  != 5'b0 && ex_rd  == id_rs1) fwd_rs1 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs1) fwd_rs1 = 2'd2;
    else                                                     fwd_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_w_en  && ex_rd  != 5'b0 && ex_rd  == id_rs2) fwd_rs2 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs2) fwd_rs2 = 2'd2;
    else                                                     fwd_rs2 = 2'd0;
  end

endmodule
