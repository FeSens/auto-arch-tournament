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
// Reset clears validity, leaving the distributed RAM words unreset. Reads
// of unwritten registers return zero; no RAM initialization is assumed.
// Same-cycle write bypass remains active during reset, as before.
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
  logic rs1_bypass, rs2_bypass;
  logic rs1_stored, rs2_stored;

  always_ff @(posedge clock) begin
    if (!reset && w_en && w_addr != 5'b0)
      regs[w_addr] <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      written_q <= '0;
    end else if (w_en && w_addr != 5'b0) begin
      written_q[w_addr] <= 1'b1;
    end
  end

  always_comb begin
    rs1_bypass = w_en && w_addr == rs1_addr && rs1_addr != 5'b0;
    rs2_bypass = w_en && w_addr == rs2_addr && rs2_addr != 5'b0;
    rs1_stored = !rs1_bypass && written_q[rs1_addr] && rs1_addr != 5'b0;
    rs2_stored = !rs2_bypass && written_q[rs2_addr] && rs2_addr != 5'b0;

    rs1_data = ({32{rs1_bypass}} & w_data) |
               ({32{rs1_stored}} & regs[rs1_addr]);
    rs2_data = ({32{rs2_bypass}} & w_data) |
               ({32{rs2_stored}} & regs[rs2_addr]);
  end

endmodule
