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
// Fixed-address flop words, with four banks of eight logical rows. x0
// has no storage. Shared one-hot decode and balanced masked-OR trees
// give each read port an asynchronous path without RAM inference.
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

  logic [3:0] write_bank, read1_bank, read2_bank;
  logic [7:0] write_row, read1_row, read2_row;
  logic [31:0] bank1_data [0:3], bank2_data [0:3];
  logic [31:0] read1_data, read2_data;

  for (genvar b = 0; b < 4; b++) begin : g_bank
    assign write_bank[b] = w_en && w_addr != 5'b0 && w_addr[4:3] == 2'(b);
    assign read1_bank[b] = rs1_addr[4:3] == 2'(b);
    assign read2_bank[b] = rs2_addr[4:3] == 2'(b);
    logic [31:0] masked1 [0:7], masked2 [0:7];
    for (genvar r = 0; r < 8; r++) begin : g_word
      wire [31:0] value;
      if (b == 0 && r == 0) begin : g_zero
        assign value = 32'b0;
      end else begin : g_flop
        (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
        logic [31:0] word_q;
        wire word_enable = write_bank[b] && write_row[r];
        always_ff @(posedge clock) begin
          if (reset) word_q <= 32'b0;
          else if (word_enable) word_q <= w_data;
        end
        assign value = word_q;
      end
      // Each word's one-bit select is shared by all 32 data bits.
      wire read1_enable = read1_bank[b] && read1_row[r];
      wire read2_enable = read2_bank[b] && read2_row[r];
      assign masked1[r] = value & {32{read1_enable}};
      assign masked2[r] = value & {32{read2_enable}};
    end
    assign bank1_data[b] = (((masked1[0] | masked1[1]) |
                            (masked1[2] | masked1[3])) |
                           ((masked1[4] | masked1[5]) |
                            (masked1[6] | masked1[7])));
    assign bank2_data[b] = (((masked2[0] | masked2[1]) |
                            (masked2[2] | masked2[3])) |
                           ((masked2[4] | masked2[5]) |
                            (masked2[6] | masked2[7])));
  end
  for (genvar r = 0; r < 8; r++) begin : g_row_decode
    assign write_row[r] = w_addr[2:0] == 3'(r);
    assign read1_row[r] = rs1_addr[2:0] == 3'(r);
    assign read2_row[r] = rs2_addr[2:0] == 3'(r);
  end
  assign read1_data = (bank1_data[0] | bank1_data[1]) |
                      (bank1_data[2] | bank1_data[3]);
  assign read2_data = (bank2_data[0] | bank2_data[1]) |
                      (bank2_data[2] | bank2_data[3]);

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = read1_data;

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = read2_data;
  end

endmodule
