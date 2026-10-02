// rtl/forward_unit.sv
//
// Preselect forwarding for raw decode sources at the ID/EX edge.
// Today's eligible EX and MEM producers advance to tomorrow's sources:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the in-flight ALU result from the EX/MEM register
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX > MEM > captured RF (younger writer wins, x0 excluded).
// Producer enables include validity and each stage's trap suppression.
// Sideband state preserves the packed ID/EX payload and prediction offsets.
//
// Latency:        1 cycle, with exactly the ID/EX reset and true hold.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       hold,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] ex_rd,
  input  logic       ex_w_en,
  input  logic [4:0] mem_rd,
  input  logic       mem_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);
  logic [1:0] next_rs1, next_rs2;

  // Yosys's Verilog frontend rejects SV-style `function … return …`,
  // so the per-rs selection is open-coded in two always_comb blocks.
  always_comb begin
    if      (ex_w_en && ex_rd != 5'b0 && ex_rd == id_rs1) next_rs1 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs1) next_rs1 = 2'd2;
    else                                                   next_rs1 = 2'd0;
  end

  always_comb begin
    if      (ex_w_en && ex_rd != 5'b0 && ex_rd == id_rs2) next_rs2 = 2'd1;
    else if (mem_w_en && mem_rd != 5'b0 && mem_rd == id_rs2) next_rs2 = 2'd2;
    else                                                   next_rs2 = 2'd0;
  end

  // Kill and fetch readiness affect only ID/EX valid, never this enable.
  // A load-use bubble captures metadata; its replay selects the MEM load
  // that will become WB. Downstream holds retain the same association.
  always_ff @(posedge clock) begin
    if (reset) begin
      fwd_rs1 <= 2'd0;
      fwd_rs2 <= 2'd0;
    end else if (!hold) begin
      fwd_rs1 <= next_rs1;
      fwd_rs2 <= next_rs2;
    end
  end

endmodule
