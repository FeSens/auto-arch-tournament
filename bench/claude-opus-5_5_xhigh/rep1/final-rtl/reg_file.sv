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
// The GPRs have no reset: RISC-V does not define their reset value, and
// the simulators (Verilator cocotb / cosim) zero-initialize them. With a
// plain write port the array infers distributed LUT RAM (Gowin
// RAM16SDP4, one bank per read port) instead of 992 flops and two 32:1
// LUT read-mux trees. `reset` is kept on the port list for the instance
// and unit-test interface only.
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata, rd_wdata.
module reg_file (
  input  logic        clock,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        reset,
  /* verilator lint_on UNUSEDSIGNAL */

  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  logic [31:0] regs [0:31];

  always_ff @(posedge clock) begin
    if (w_en && w_addr != 5'b0) regs[w_addr] <= w_data;
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
