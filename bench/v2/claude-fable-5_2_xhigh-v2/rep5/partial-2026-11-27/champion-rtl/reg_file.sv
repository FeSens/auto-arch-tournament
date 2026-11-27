// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, distributed (LUT) RAM.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two combinational read ports.
//   - Single synchronous write port.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value, so ID sees WB-stage writes within the same cycle.
//
// The storage array has NO reset (a reset loop forces flops or lets the
// vendor tool fold the array + ID/EX operand registers into block RAM).
// "Reads as zero after reset" is preserved with a 32-bit `written` mask
// that IS reset: a register reads 0 until its first write. x0 is never
// marked written, which also implements the x0 hardwire.
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

  logic [31:0] regs [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [31:0] written;

  logic w_do;
  assign w_do = w_en && (w_addr != 5'b0);

  always_ff @(posedge clock) begin
    if (w_do) regs[w_addr] <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset)     written <= 32'b0;
    else if (w_do) written[w_addr] <= 1'b1;
  end

  always_comb begin
    if (w_do && w_addr == rs1_addr)
      rs1_data = w_data;
    else if (written[rs1_addr])
      rs1_data = regs[rs1_addr];
    else
      rs1_data = 32'b0;

    if (w_do && w_addr == rs2_addr)
      rs2_data = w_data;
    else if (written[rs2_addr])
      rs2_data = regs[rs2_addr];
    else
      rs2_data = 32'b0;
  end

endmodule
