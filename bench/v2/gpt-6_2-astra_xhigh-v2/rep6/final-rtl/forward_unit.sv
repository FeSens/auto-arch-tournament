// rtl/forward_unit.sv
//
// Generate one-hot operand enables from the youngest matching writer.
// The speculative load enable is independent of verification in MEM.
//
// Decode compares the incoming rs against the next cycle's MEM and WB
// destinations so register-number comparisons stay off the EX data path.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       hold_id,
  input  logic       hold_mem,
  input  logic [4:0] decode_rs,
  input  logic       decode_uses_rs,
  input  logic       alu_uses_rs,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_load,
  input  logic       ex_will_write,
  input  logic [4:0] ex_mem_rd,
  input  logic       mem_will_write,
  output bypass_t    sel,
  output bypass_t    alu_sel,
  output logic       trace_load
);

  logic raw_match, raw_match_q, from_mem, from_wb;
  assign raw_match = id_ex_rd != 0 && id_ex_rd == decode_rs;
  assign from_mem = ex_will_write && raw_match && (decode_uses_rs || !id_ex_load);
  assign from_wb = mem_will_write && ex_mem_rd != 0 && ex_mem_rd == decode_rs;

  bypass_t next_sel;
  always_comb begin
    if (hold_id) begin
      // EX inserts a bubble and the held instruction's MEM source
      // moves to WB. The saved match names that instruction's rs.
      next_sel.captured = !(mem_will_write && raw_match_q);
      next_sel.mem_wb   = mem_will_write && raw_match_q;
      next_sel.ex_mem   = 1'b0;
      next_sel.load     = 1'b0;
    end else begin
      next_sel.captured = !from_mem && !from_wb;
      next_sel.mem_wb   = !from_mem && from_wb;
      next_sel.ex_mem   = from_mem && !id_ex_load;
      next_sel.load     = from_mem && id_ex_load;
    end
  end

  // Capture each bypass enable with its producer's result. This keeps
  // write-enable qualification and priority off the signed WB data path.
  always_ff @(posedge clock) begin
    if (!hold_id) raw_match_q <= raw_match;
    if (reset) begin
      sel <= 4'b1000;
      alu_sel <= '0;
      trace_load <= 1'b0;
    end else if (!hold_mem) begin
      sel        <= next_sel;
      alu_sel    <= alu_uses_rs ? next_sel : '0;
      trace_load <= !hold_id && ex_will_write && raw_match && !decode_uses_rs && id_ex_load;
    end
  end

endmodule
