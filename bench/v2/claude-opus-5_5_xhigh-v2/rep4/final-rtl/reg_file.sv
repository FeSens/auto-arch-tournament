// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two asynchronous (combinational) read ports.
//   - Single synchronous write port.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value, so ID sees the WB-stage write within the same cycle.
//
// Inferred as distributed LUT-RAM (no reset loop): the read data is
// combinational, so ID registers the final bypassed value into fabric
// ID/EX flops instead of the ID/EX operand register being a BSRAM output
// register (2.3 ns tC2Q at the head of every EX path).
//
// The reset clear exists for Verilator only (cocotb re-runs programs
// back-to-back and cosim starts from all-zero registers); synthesis and
// formal see a plain RAM whose contents are architecturally undefined
// until written.
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

  (* syn_ramstyle = "distributed_ram" *)
  logic [31:0] regs [0:31];

`ifdef VERILATOR
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'b0;
    end else if (w_en && w_addr != 5'b0) begin
      regs[w_addr] <= w_data;
    end
  end
`else
  always_ff @(posedge clock) begin
    if (w_en && w_addr != 5'b0) begin
      regs[w_addr] <= w_data;
    end
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
