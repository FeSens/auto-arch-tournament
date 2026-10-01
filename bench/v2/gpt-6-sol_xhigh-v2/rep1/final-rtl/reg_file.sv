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
// Reset clears every architectural register. Explicit per-register enables
// prevent the read port from being absorbed into a synchronous block RAM.
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

  // Individually enabled registers keep the two read ports combinational
  // through ID/EX. A monolithic array can infer a synchronous block RAM
  // whose output register is merged into ID/EX, putting a RAM read and the
  // whole EX comparator/shifter in one timed path.
  logic [31:0] regs [1:31];
  for (genvar i = 1; i < 32; i++) begin : g_reg
    always_ff @(posedge clock) begin
      if (reset) regs[i] <= 32'b0;
      else if (w_en && w_addr == 5'(i)) regs[i] <= w_data;
    end
  end

  logic [31:0] rs1_stored;
  logic [31:0] rs2_stored;
  always_comb begin
    rs1_stored = 32'b0;
    rs2_stored = 32'b0;
    for (int i = 1; i < 32; i++) begin
      rs1_stored |= regs[i] & {32{rs1_addr == 5'(i)}};
      rs2_stored |= regs[i] & {32{rs2_addr == 5'(i)}};
    end
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = rs1_stored;

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = rs2_stored;
  end

endmodule
