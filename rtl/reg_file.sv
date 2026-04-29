// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two combinational read ports.
//   - Single synchronous write port.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value. This matches the prior Chisel core's RegFile.scala
//     and lets the ID stage see WB-stage writes within the same cycle
//     without an extra forwarding mux.
//
// Reset clears only the valid mask. The data payload is intentionally
// resetless so synthesis can infer cheap distributed RAM instead of a bank of
// resettable flops. Invalid nonzero registers read as zero until their first
// write after reset.
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata, rd_wdata.
module reg_file (
  input  logic        clock,
  input  logic        reset,

  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  (* ram_style = "distributed" *) logic [31:0] regs_rs1 [0:31];
  (* ram_style = "distributed" *) logic [31:0] regs_rs2 [0:31];
  logic [31:0] valid_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= 32'b0;
    end else if (w_en && w_addr != 5'b0) begin
      regs_rs1[w_addr] <= w_data;
      regs_rs2[w_addr] <= w_data;
      valid_q[w_addr]  <= 1'b1;
    end
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else if (valid_q[rs1_addr])
      rs1_data = regs_rs1[rs1_addr];
    else
      rs1_data = 32'b0;

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else if (valid_q[rs2_addr])
      rs2_data = regs_rs2[rs2_addr];
    else
      rs2_data = 32'b0;
  end

endmodule
