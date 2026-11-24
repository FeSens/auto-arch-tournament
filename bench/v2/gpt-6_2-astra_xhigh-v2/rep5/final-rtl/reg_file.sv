// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two combinational read ports.
//   - Single synchronous write port.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value to ID. Fetch reads the same arrays before the bypass.
//
// Each asynchronous read port has a RAM replica. Only the shared written
// bits need reset. An unwritten register (including x0) always reads zero.
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
  output logic [31:0] rs1_array,
  output logic [31:0] rs2_array,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  (* syn_ramstyle = "distributed_ram" *) logic [31:0] regs_rs1 [0:31];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] regs_rs2 [0:31];
  logic [31:0] written;
  logic write_word;

  assign write_word = w_en && w_addr != 5'd0;

  always_ff @(posedge clock) begin
    if (write_word) begin
      regs_rs1[w_addr] <= w_data;
      regs_rs2[w_addr] <= w_data;
    end
    if (reset)
      written <= '0;
    else if (write_word)
      written[w_addr] <= 1'b1;
  end

  assign rs1_array = written[rs1_addr] ? regs_rs1[rs1_addr] : 32'b0;
  assign rs2_array = written[rs2_addr] ? regs_rs2[rs2_addr] : 32'b0;
  assign rs1_data = write_word && w_addr == rs1_addr ? w_data : rs1_array;
  assign rs2_data = write_word && w_addr == rs2_addr ? w_data : rs2_array;

endmodule
