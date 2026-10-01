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
// Each read port has a coherent copy of two 16-word distributed-RAM banks.
// Only written bits reset: unwritten payload is hidden until the next write.
// Reset suppresses storage writes but leaves combinational bypass unchanged.
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

  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank1_lo [0:15];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank1_hi [0:15];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank2_lo [0:15];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] bank2_hi [0:15];
  logic [31:0] written_q;
  logic [31:0] stored1, stored2;
  logic write_accept;

  assign write_accept = !reset && w_en && w_addr != 5'b0;
  assign stored1 = rs1_addr[4] ? bank1_hi[rs1_addr[3:0]]
                               : bank1_lo[rs1_addr[3:0]];
  assign stored2 = rs2_addr[4] ? bank2_hi[rs2_addr[3:0]]
                               : bank2_lo[rs2_addr[3:0]];

  always_ff @(posedge clock) begin
    if (reset) written_q <= 32'b0;
    else if (write_accept) written_q[w_addr] <= 1'b1;
  end

  // Payload has no reset so each bank infers asynchronous-read RAM.
  always_ff @(posedge clock) begin
    if (write_accept) begin
      if (!w_addr[4]) begin
        bank1_lo[w_addr[3:0]] <= w_data;
        bank2_lo[w_addr[3:0]] <= w_data;
      end else begin
        bank1_hi[w_addr[3:0]] <= w_data;
        bank2_hi[w_addr[3:0]] <= w_data;
      end
    end
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else if (written_q[rs1_addr])
      rs1_data = stored1;
    else
      rs1_data = 32'b0;

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else if (written_q[rs2_addr])
      rs2_data = stored2;
    else
      rs2_data = 32'b0;
  end

endmodule
