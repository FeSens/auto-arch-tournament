// rtl/forward_unit.sv
//
// ID-side operand bypass select generator. Forwarding is resolved in ID and
// captured into the ID/EX register, so EX reads only ID/EX flops. For the
// instruction in ID (RAW fetched rs1/rs2 fields) the freshest producer is:
//   P1 : the instruction currently in EX  (its ex_stage result)
//   P2 : the instruction currently in MEM (EX/MEM; ALU result or load data)
//   else the regfile read. The regfile is written from the MEM stage (end of
//   the cycle the instruction is in MEM), so the instruction in WB is already
//   in the regfile: there is no P3 case and no write-first bypass.
//
// Priority is P1 > P2 (younger writer wins). The *_en inputs already fold in
// reg_write (trap-gated) and rd != 0 (id_stage), so x0 never hits. The raw
// hits are returned: p2 is NOT qualified by !p1. The priority-form consumers
// (rs1_val / rs2_val) check p1 first; the one-hot AND-OR consumer (alu_b)
// adds the !p1 qualification itself.
//
// A load in EX is not forwarded (hazard_unit bubbles its consumer by one
// cycle); one cycle later it is the P2 producer and its load data is bypassed.
//
// Latency:        combinational.
// RVFI fields:    n/a — selects feed id_stage's rs1_val / rs2_val capture.
module forward_unit (
  input  logic [4:0] rs1,          // ID-stage rs1 (raw instr[19:15])
  input  logic [4:0] rs2,          // ID-stage rs2 (raw instr[24:20])
  input  logic [4:0] ex_rd,        // ID/EX.rd     (instruction in EX)
  input  logic       ex_res_en,    // EX result is a real, non-x0 register write
  input  logic [4:0] mem_rd,       // EX/MEM.rd    (instruction in MEM)
  input  logic       mem_res_en,   // MEM result is a real, non-x0 register write
  output logic       p1_hit_rs1,
  output logic       p2_hit_rs1,
  output logic       p1_hit_rs2,
  output logic       p2_hit_rs2
);

  always_comb begin
    p1_hit_rs1 = ex_res_en  && (ex_rd  == rs1);
    p2_hit_rs1 = mem_res_en && (mem_rd == rs1);
    p1_hit_rs2 = ex_res_en  && (ex_rd  == rs2);
    p2_hit_rs2 = mem_res_en && (mem_rd == rs2);
  end

endmodule
