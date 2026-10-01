// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, built from fabric flip-flops.
//   - x1..x31 are 31 explicit 32-bit registers (one generate block each,
//     write enable = w_en && w_addr == i). x0 is the constant 0 and has no
//     storage. syn_ramstyle = "registers" keeps synthesis from mapping the
//     array to BSRAM or LUT-RAM.
//   - Two combinational 32:1 read ports. The read runs in ID, addressed by
//     the raw IF/ID word; id_stage merges in the write-first bypass and
//     latches the result into ID/EX as a plain fabric FF (it is no longer
//     the BSRAM read register).
//   - Single synchronous write port; x0 writes are dropped.
//   - No reset and no internal bypass. The registers are zero-filled by an
//     `initial` block (simulation / formal parity with the old BSRAM init).
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata, rd_wdata.
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

  // Read view: entry 0 is the constant 0, entries 1..31 the registers.
  logic [31:0] regs [0:31] /* synthesis syn_ramstyle = "registers" */;

  assign regs[0] = 32'b0;

  for (genvar i = 1; i < 32; i++) begin : g_reg
    logic [31:0] q /* synthesis syn_ramstyle = "registers" */;

    initial q = 32'b0;

    always_ff @(posedge clock) begin
      if (w_en && w_addr == 5'(i)) q <= w_data;
    end

    assign regs[i] = q;
  end

  assign rs1_data = regs[rs1_addr];
  assign rs2_data = regs[rs2_addr];

endmodule
