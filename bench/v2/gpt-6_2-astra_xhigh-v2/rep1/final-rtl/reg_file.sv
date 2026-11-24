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
// A written bit per word provides the architectural reset value while the
// two distributed RAM banks retain their contents across reset.
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

  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank_lo [0:15];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank_hi [0:15];
  logic [31:0] written;
  logic write_word;
  assign write_word = w_en && w_addr != 5'b0;

  always_ff @(posedge clock) begin
    if (write_word && !w_addr[4]) bank_lo[w_addr[3:0]] <= w_data;
    if (write_word &&  w_addr[4]) bank_hi[w_addr[3:0]] <= w_data;

    if (reset)           written <= '0;
    else if (write_word) written[w_addr] <= 1'b1;
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else if (!written[rs1_addr])
      rs1_data = 32'b0;
    else
      rs1_data = rs1_addr[4] ? bank_hi[rs1_addr[3:0]] : bank_lo[rs1_addr[3:0]];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else if (!written[rs2_addr])
      rs2_data = 32'b0;
    else
      rs2_data = rs2_addr[4] ? bank_hi[rs2_addr[3:0]] : bank_lo[rs2_addr[3:0]];
  end

endmodule
