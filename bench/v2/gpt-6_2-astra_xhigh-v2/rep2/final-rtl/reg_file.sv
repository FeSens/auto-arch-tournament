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
// Reset the written bits to make every architectural register read zero.
// The data RAM then needs only its normal write port.
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

  (* syn_ramstyle = "distributed_ram", ram_style = "distributed" *)
  logic [31:0] regs [0:31];
  logic [31:0] written;
  logic        write_reg, bypass1, bypass2;
  assign write_reg = w_en && w_addr != 0;

  always_ff @(posedge clock) begin
    if (write_reg)
      regs[w_addr] <= w_data;
    if (reset)
      written <= '0;
    else if (write_reg)
      written[w_addr] <= 1'b1;
  end

  // Selectors operate in parallel with the two asynchronous data reads.
  assign bypass1 = write_reg && w_addr == rs1_addr;
  assign bypass2 = write_reg && w_addr == rs2_addr;
  assign rs1_data = ({32{written[rs1_addr] && !bypass1}} & regs[rs1_addr])
                  | ({32{bypass1}} & w_data);
  assign rs2_data = ({32{written[rs2_addr] && !bypass2}} & regs[rs2_addr])
                  | ({32{bypass2}} & w_data);

endmodule
