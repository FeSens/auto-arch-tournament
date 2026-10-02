// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, built from explicit flops (one
// write-enabled 32-bit register per index, x0 a constant 0).
//   - x0 is never written and reads as the constant 0, so an x0 operand
//     needs no mux anywhere downstream.
//   - Two plain combinational read ports (no write-first bypass). A
//     same-cycle write to the read address returns the OLD value; the
//     WB-stage producer is forwarded by id_stage's wb-now term instead,
//     which keeps the bypass LUT off the regfile output path.
//   - Single synchronous write port, reset clears x1..x31.
//
// The read data is consumed inside the ID cycle (it feeds the ID/EX operand
// flops through the forward AND-OR), so it must be a flop-fed mux, not a
// BSRAM output that appears after the ID/EX boundary.
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

  logic [31:0][31:0] regs;

  assign regs[0] = 32'b0;

  for (genvar i = 1; i < 32; i++) begin : g_reg
    (* syn_ramstyle = "registers" *) logic [31:0] r_q;
    always_ff @(posedge clock) begin
      if (reset)                         r_q <= 32'b0;
      else if (w_en && w_addr == 5'(i))  r_q <= w_data;
    end
    assign regs[i] = r_q;
  end

  assign rs1_data = regs[rs1_addr];
  assign rs2_data = regs[rs2_addr];

endmodule
