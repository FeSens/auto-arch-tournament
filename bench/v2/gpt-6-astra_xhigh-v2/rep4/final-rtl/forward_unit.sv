// rtl/forward_unit.sv
//
// Operand forwarding decisions captured alongside ID/EX. Compare decode's
// sources with the owners that will enter EX/MEM and ordinary MEM/WB on
// this same advancing edge, so EX starts with registered mux selections:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the in-flight ALU result from the EX/MEM register
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Latency:        existing ID/EX boundary (no additional pipeline stage).
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       capture,
  input  logic       squash,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] next_ex_mem_rd,
  input  logic       next_ex_mem_w_en,
  input  logic [4:0] next_mem_wb_rd,
  input  logic       next_mem_wb_w_en,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  logic [1:0] next_rs1, next_rs2;

  always_comb begin
    if (next_ex_mem_w_en && next_ex_mem_rd != 5'b0 && next_ex_mem_rd == id_rs1)
      next_rs1 = 2'd1;
    else if (next_mem_wb_w_en && next_mem_wb_rd != 5'b0 && next_mem_wb_rd == id_rs1)
      next_rs1 = 2'd2;
    else
      next_rs1 = 2'd0;
  end

  always_comb begin
    if (next_ex_mem_w_en && next_ex_mem_rd != 5'b0 && next_ex_mem_rd == id_rs2)
      next_rs2 = 2'd1;
    else if (next_mem_wb_w_en && next_mem_wb_rd != 5'b0 && next_mem_wb_rd == id_rs2)
      next_rs2 = 2'd2;
    else
      next_rs2 = 2'd0;
  end

  // Exactly ID/EX's reset/squash/hold priority. WB ownership survives a
  // dmem hold even after its retirement valid clears. Divide operands are
  // snapshotted on launch before these older forwarding entries drain.
  always_ff @(posedge clock) begin
    if (reset || squash) begin
      fwd_rs1 <= 2'd0;
      fwd_rs2 <= 2'd0;
    end else if (capture) begin
      fwd_rs1 <= next_rs1;
      fwd_rs2 <= next_rs2;
    end
  end

endmodule
