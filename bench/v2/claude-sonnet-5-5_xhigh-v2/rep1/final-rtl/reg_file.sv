// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, built from explicit fabric flops.
//   - x0 hardwired to zero (no storage; writes dropped, reads always 0).
//   - Two combinational read ports (32:1 muxes over the register flops).
//   - Single synchronous write port, one-hot write enable per register.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value. This matches the prior Chisel core's RegFile.scala
//     and lets the ID stage see WB-stage writes within the same cycle
//     without an extra forwarding mux.
//
// Each register is its own always_ff in a generate loop (no `regs[addr]`
// array), so Gowin synthesis cannot pattern-match the storage into a
// sync-read BSRAM / SSRAM. The ID/EX rs?_val flops that capture the read
// data are therefore ordinary fabric flops (~0.5 ns tC2Q) instead of a
// BSRAM output register (~2.3 ns tC2Q) on the EX critical cones.
//
// The reset clears all 31 registers (synchronous; maps onto the flop's
// native sync-reset, write enable onto its CE).
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

  // regs_q[0] is the x0 constant; regs_q[1..31] are flop outputs.
  logic [31:0] regs_q [0:31];

  assign regs_q[0] = 32'b0;

  for (genvar i = 1; i < 32; i++) begin : g_reg
    logic        we;
    logic [31:0] r;

    assign we = w_en && (w_addr == 5'(i));

    always_ff @(posedge clock) begin
      if (reset)   r <= 32'b0;
      else if (we) r <= w_data;
    end

    assign regs_q[i] = r;
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = regs_q[rs1_addr];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = regs_q[rs2_addr];
  end

endmodule
