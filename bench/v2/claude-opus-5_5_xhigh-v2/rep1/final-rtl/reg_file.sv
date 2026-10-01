// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero (writes silently dropped, reads always 0).
//   - Two combinational (asynchronous) read ports.
//   - Single synchronous write port.
//
// No write-first bypass and no reset: the ID-stage forward mux
// (id_stage.sv, source c = MEM/WB) covers a same-cycle write, and the
// read data feeds that mux rather than a flop, so synthesis maps the
// array to async LUT-RAM instead of a registered-read BSRAM absorbing
// ID/EX. x1..x31 have no reset requirement (programs initialize
// registers before use); x0 is forced to 0 on read.
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata (via the ID forward mux).
module reg_file (
  input  logic        clock,

  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  // One 1W/1R bank per read port (identical contents): each maps to plain
  // simple-dual-port LUT-RAM. (A single array with two async read ports
  // stops Gowin synthesis in RAM inference.)
  logic [31:0] regs_a [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
  logic [31:0] regs_b [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;

  always_ff @(posedge clock) begin
    if (w_en && w_addr != 5'b0) begin
      regs_a[w_addr] <= w_data;
      regs_b[w_addr] <= w_data;
    end
  end

  always_comb begin
    rs1_data = (rs1_addr == 5'b0) ? 32'b0 : regs_a[rs1_addr];
    rs2_data = (rs2_addr == 5'b0) ? 32'b0 : regs_b[rs2_addr];
  end

endmodule
