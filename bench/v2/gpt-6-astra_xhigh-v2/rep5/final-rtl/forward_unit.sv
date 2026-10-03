// rtl/forward_unit.sv
//
// Predict complete operand sources alongside ID/EX. The EX producer's
// decoded write intent predicts successful completion; the MEM producer's
// alignment/write permission is already resolved at this capture boundary.
// One-hot encoding: RF, EX/MEM ALU, MEM/WB ALU, MEM/WB load (bits 0..3).
// Actual write permissions feed only verification, never the source masks.
//
// Priority is EX/MEM > MEM/WB > none (younger writer wins, x0 always 0).
//
// Latency:        sources captured on the existing ID/EX edge.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       stall_id,
  input  logic       flush_id,
  input  logic       stall_ex_mem,
  input  logic       id_valid,
  input  logic [4:0] id_rs1,
  input  logic [4:0] id_rs2,
  input  logic [4:0] id_ex_rd,
  input  logic       id_ex_w_intent,
  input  logic [4:0] ex_mem_rd,
  input  logic       mem_w_permission,
  input  logic       ex_mem_load,
  input  logic       ex_mem_w_en,
  input  logic       mem_wb_w_en,
  output logic [3:0] fwd_rs1,
  output logic [3:0] fwd_rs2,
  output logic       prediction_failed
);

  logic rs1_ex, rs2_ex, rs1_wb, rs2_wb;
  logic ex_failed, wb_failed;

  always_comb begin
    rs1_ex = id_ex_w_intent && id_ex_rd != 0 && id_ex_rd == id_rs1;
    rs2_ex = id_ex_w_intent && id_ex_rd != 0 && id_ex_rd == id_rs2;
    rs1_wb = mem_w_permission && ex_mem_rd != 0 && ex_mem_rd == id_rs1 && !rs1_ex;
    rs2_wb = mem_w_permission && ex_mem_rd != 0 && ex_mem_rd == id_rs2 && !rs2_ex;
  end

  always_ff @(posedge clock) begin
    // Match the ID/EX reset/flush/hold/invalid priorities exactly.
    if (reset || flush_id) begin
      fwd_rs1 <= '0;
      fwd_rs2 <= '0;
    end else if (stall_id) begin
      if (!stall_ex_mem) begin
        // M wait: the old EX/MEM producer advances to WB and EX/MEM
        // becomes a bubble. M has captured its validated raw operands on
        // launch, so drained WB sources are no longer needed. Never sample
        // a held instruction's changing queue head.
        fwd_rs1 <= {fwd_rs1[1] && ex_mem_load,
                    fwd_rs1[1] && !ex_mem_load, 1'b0, !fwd_rs1[1]};
        fwd_rs2 <= {fwd_rs2[1] && ex_mem_load,
                    fwd_rs2[1] && !ex_mem_load, 1'b0, !fwd_rs2[1]};
      end
      // dmem hold retains both producer payloads and both source sets.
    end else if (!id_valid) begin
      fwd_rs1 <= '0;
      fwd_rs2 <= '0;
    end else begin
      fwd_rs1 <= {rs1_wb && ex_mem_load, rs1_wb && !ex_mem_load,
                  rs1_ex, !(rs1_ex || rs1_wb)};
      fwd_rs2 <= {rs2_wb && ex_mem_load, rs2_wb && !ex_mem_load,
                  rs2_ex, !(rs2_ex || rs2_wb)};
    end
  end

  // WB permission is known before capture, but validate it independently.
  // Retained WB payload/permission stays usable after retirement-valid clears.
  assign ex_failed = (fwd_rs1[1] || fwd_rs2[1]) && !ex_mem_w_en;
  assign wb_failed = (|fwd_rs1[3:2] || |fwd_rs2[3:2]) && !mem_wb_w_en;
  assign prediction_failed = ex_failed || wb_failed;

endmodule
