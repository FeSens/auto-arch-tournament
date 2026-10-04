// rtl/forward_unit.sv
//
// D-side youngest-writer selection: 0 = register file (with W bypass),
// 1 = X ordinary result, 2 = M completed architectural result.
// An unfinished X match blocks D, never falling through to an older writer.
//
// Latency:        combinational.
// RVFI fields:    feeds rs1_rdata / rs2_rdata through D operand capture.
module forward_unit (
  input  logic [4:0] d_rs1,
  input  logic [4:0] d_rs2,
  input  logic [4:0] x_rd,
  input  logic       x_write,
  input  logic       x_pending,
  input  logic [4:0] m_rd,
  input  logic       m_write,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2,
  output logic       operand_wait
);

  // Interlocks use only captured producer class/validity and register
  // matches, independently of trap-aware completed-result selection.
  assign operand_wait = x_pending &&
                       ((d_rs1 != 0 && x_rd == d_rs1) ||
                        (d_rs2 != 0 && x_rd == d_rs2));
  always_comb begin
    fwd_rs1 = 2'd0;
    fwd_rs2 = 2'd0;
    if (d_rs1 != 0) begin
      if (x_write && x_rd == d_rs1) begin
        fwd_rs1 = 2'd1;
      end else if (m_write && m_rd == d_rs1) fwd_rs1 = 2'd2;
    end
    if (d_rs2 != 0) begin
      if (x_write && x_rd == d_rs2) begin
        fwd_rs2 = 2'd1;
      end else if (m_write && m_rd == d_rs2) fwd_rs2 = 2'd2;
    end
  end

endmodule
