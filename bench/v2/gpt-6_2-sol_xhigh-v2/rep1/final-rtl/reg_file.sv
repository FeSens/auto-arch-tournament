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
// The reset clears all 32 registers. Distributed-LUT or flop inference is
// fine here; explicit BRAM attribution lives on the larger imem/dmem
// declarations in soc.sv (phase 5).
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

  logic [31:0] regs [0:31];
  logic write_reg;
  logic bypass_rs1, bypass_rs2, read_rs1, read_rs2;

  assign write_reg = w_en && w_addr != 5'b0;

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'b0;
    end else if (write_reg) begin
      regs[w_addr] <= w_data;
    end
  end

  // Resolve x0 and write-first priority in the one-hot read enables.
  assign bypass_rs1 = write_reg && w_addr == rs1_addr;
  assign bypass_rs2 = write_reg && w_addr == rs2_addr;
  assign read_rs1 = rs1_addr != 5'b0 && !bypass_rs1;
  assign read_rs2 = rs2_addr != 5'b0 && !bypass_rs2;

  assign rs1_data = ({32{read_rs1}} & regs[rs1_addr]) | ({32{bypass_rs1}} & w_data);
  assign rs2_data = ({32{read_rs2}} & regs[rs2_addr]) | ({32{bypass_rs2}} & w_data);

endmodule
