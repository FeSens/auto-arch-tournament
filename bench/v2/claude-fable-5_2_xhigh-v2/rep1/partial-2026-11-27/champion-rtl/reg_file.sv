// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, distributed (LUT) RAM.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two combinational (asynchronous) read ports.
//   - Single synchronous write port.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value, so the ID stage sees WB-stage writes within the same
//     cycle without an extra forwarding mux.
//
// There is NO reset loop any more: a per-entry reset forces the array into
// flops (or, on Gowin, into a BSRAM folded together with the ID/EX operand
// registers, which put a 2.3 ns clk-to-out at the head of the EX cone).
// The array is zero-initialised instead (power-up / simulation), and the
// write enable is gated by !reset so nothing is written while the pipeline
// registers are being cleared.
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

  initial begin
    for (int i = 0; i < 32; i++) regs[i] = 32'b0;
  end

  always_ff @(posedge clock) begin
    if (!reset && w_en && w_addr != 5'b0) begin
      regs[w_addr] <= w_data;
    end
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = regs[rs1_addr];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = regs[rs2_addr];
  end

endmodule
