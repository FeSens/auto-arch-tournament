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
// Reset clears only the written bitmap. Unwritten words read as zero,
// allowing the payload to infer distributed RAM without reset logic.
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
  logic [31:0] written_q;
  logic        write_en;
  logic        rs1_bypass, rs2_bypass;
  logic        rs1_ram_en, rs2_ram_en;

  assign write_en = w_en && (w_addr != 5'd0);

  always_ff @(posedge clock) begin
    if (write_en) regs[w_addr] <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset)         written_q <= '0;
    else if (write_en) written_q[w_addr] <= 1'b1;
  end

  assign rs1_bypass = write_en && (w_addr == rs1_addr);
  assign rs2_bypass = write_en && (w_addr == rs2_addr);
  assign rs1_ram_en = (rs1_addr != 5'd0) && written_q[rs1_addr] && !rs1_bypass;
  assign rs2_ram_en = (rs2_addr != 5'd0) && written_q[rs2_addr] && !rs2_bypass;

  assign rs1_data = ({32{rs1_bypass}} & w_data) | ({32{rs1_ram_en}} & regs[rs1_addr]);
  assign rs2_data = ({32{rs2_bypass}} & w_data) | ({32{rs2_ram_en}} & regs[rs2_addr]);

endmodule
