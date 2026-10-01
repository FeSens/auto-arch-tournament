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
// The array is forced out of block RAM (syn_ramstyle): Gowin BSRAM only
// reads synchronously, so it folded the ID/EX rs?_val flops into the
// BSRAM read and rebuilt the bypass / ID/EX clear after its slow
// clock-to-out, at the head of every EX path. As LUT-RAM (RAM16SDP4,
// async read) the read + bypass sit in ID and ID/EX.rs?_val are real
// flops.
//
// The reset clears all 32 registers in simulation and formal (Verilator,
// riscv-formal). It is not needed architecturally (x0 reads are forced
// to 0 below, everything else is written before use) and a clear-all
// reset cannot map onto a RAM, so the synthesis build leaves it out.
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

  (* syn_ramstyle = "distributed_ram" *)
  logic [31:0] regs [0:31];

`ifdef VERILATOR
  `define REG_FILE_RESET
`elsif RISCV_FORMAL
  `define REG_FILE_RESET
`elsif FORMAL
  `define REG_FILE_RESET
`endif

`ifdef REG_FILE_RESET
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'b0;
    end else if (w_en && w_addr != 5'b0) begin
      regs[w_addr] <= w_data;
    end
  end
`else
  // Synthesis: plain write port, no reset (see header).
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_reset;
  assign unused_reset = reset;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (w_en && w_addr != 5'b0) regs[w_addr] <= w_data;
  end
`endif

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
