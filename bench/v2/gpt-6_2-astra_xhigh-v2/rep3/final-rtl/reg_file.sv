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
// Reset clears the written mask. Unwritten rows read as zero, allowing
// the data array to use distributed RAM with asynchronous reads.
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

  (* syn_ramstyle = "distributed_ram" *) logic [31:0] regs [0:31];
  logic [31:0] written;
  logic write_rd;
  assign write_rd = w_en && w_addr != 5'b0;

  always_ff @(posedge clock) begin
    if (write_rd)
      regs[w_addr] <= w_data;
  end

  assign written[0] = 1'b0;
  for (genvar r = 1; r < 32; r++) begin : gen_written
    always_ff @(posedge clock) begin
      if (reset)
        written[r] <= 1'b0;
      else if (w_en && w_addr == 5'(r))
        written[r] <= 1'b1;
    end
  end

  assign rs1_data = write_rd && w_addr == rs1_addr ? w_data
                  : written[rs1_addr] ? regs[rs1_addr] : 32'b0;
  assign rs2_data = write_rd && w_addr == rs2_addr ? w_data
                  : written[rs2_addr] ? regs[rs2_addr] : 32'b0;

endmodule
