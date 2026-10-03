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
// x1..x31 are independently enabled flop words, arranged in four banks
// of eight architectural register numbers. Constant-index masked-OR read
// trees keep storage and read selection before the ID/EX capture edge.
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

  wire [31:0] bank_rs1 [0:3];
  wire [31:0] bank_rs2 [0:3];
  wire [31:0] read_rs1, read_rs2;
  wire bypass_rs1, bypass_rs2;

  generate
    for (genvar bank = 0; bank < 4; bank++) begin : g_bank
      wire [31:0] masked_rs1 [0:7];
      wire [31:0] masked_rs2 [0:7];
      for (genvar word_idx = 0; word_idx < 8; word_idx++) begin : g_word
        localparam logic [4:0] ADDR = 5'(bank * 8 + word_idx);
        if (ADDR == 0) begin : g_zero
          assign masked_rs1[word_idx] = 32'b0;
          assign masked_rs2[word_idx] = 32'b0;
        end else begin : g_reg
          logic [31:0] word_q;
          wire write_word = w_en && w_addr == ADDR;
          always_ff @(posedge clock) begin
            if (reset) word_q <= 32'b0;
            else if (write_word) word_q <= w_data;
          end
          assign masked_rs1[word_idx] = word_q & {32{rs1_addr == ADDR}};
          assign masked_rs2[word_idx] = word_q & {32{rs2_addr == ADDR}};
        end
      end
      assign bank_rs1[bank] =
          ((masked_rs1[0] | masked_rs1[1]) | (masked_rs1[2] | masked_rs1[3])) |
          ((masked_rs1[4] | masked_rs1[5]) | (masked_rs1[6] | masked_rs1[7]));
      assign bank_rs2[bank] =
          ((masked_rs2[0] | masked_rs2[1]) | (masked_rs2[2] | masked_rs2[3])) |
          ((masked_rs2[4] | masked_rs2[5]) | (masked_rs2[6] | masked_rs2[7]));
    end
  endgenerate

  assign read_rs1 = (bank_rs1[0] | bank_rs1[1]) | (bank_rs1[2] | bank_rs1[3]);
  assign read_rs2 = (bank_rs2[0] | bank_rs2[1]) | (bank_rs2[2] | bank_rs2[3]);
  assign bypass_rs1 = w_en && w_addr != 0 && w_addr == rs1_addr;
  assign bypass_rs2 = w_en && w_addr != 0 && w_addr == rs2_addr;
  assign rs1_data = (read_rs1 & {32{!bypass_rs1}}) | (w_data & {32{bypass_rs1}});
  assign rs2_data = (read_rs2 & {32{!bypass_rs2}}) | (w_data & {32{bypass_rs2}});

endmodule
