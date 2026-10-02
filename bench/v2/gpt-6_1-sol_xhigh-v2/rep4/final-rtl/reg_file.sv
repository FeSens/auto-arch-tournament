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
// Each writable word has independent flip-flop storage, synchronous reset
// and a decoded write enable. Fixed-index read wiring prevents RAM inference
// and keeps the ID/EX operand registers outside RAM output storage.
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

  wire [31:0] words [0:31];
  wire [31:0] rs1_select, rs2_select;
  wire [7:0] rs1_low_select, rs2_low_select, write_low_select;
  wire [3:0] rs1_high_select, rs2_high_select, write_high_select;
  wire [31:0] rs1_masked [0:31], rs2_masked [0:31];
  wire [31:0] rs1_group [0:3], rs2_group [0:3];
  wire [31:0] rs1_read, rs2_read;

  assign words[0] = 32'b0;
  for (genvar r = 1; r < 32; r++) begin : g_word
    logic [31:0] word_q;
    wire write_enable = w_en && write_high_select[r/8] && write_low_select[r%8];
    always_ff @(posedge clock) begin
      if (reset) word_q <= 32'b0;
      else if (write_enable) word_q <= w_data;
    end
    assign words[r] = word_q;
  end

  // Factor each five-bit one-hot decoder into shared group/word terms.
  // Every masked word still uses the full address select; both ports can
  // choose any pair without conflicts, including within the same group.
  for (genvar n = 0; n < 8; n++) begin : g_low_decode
    localparam logic [2:0] LOW_ADDR = 3'(n);
    assign rs1_low_select[n] = (rs1_addr[2:0] == LOW_ADDR);
    assign rs2_low_select[n] = (rs2_addr[2:0] == LOW_ADDR);
    assign write_low_select[n] = (w_addr[2:0] == LOW_ADDR);
  end
  for (genvar n = 0; n < 4; n++) begin : g_high_decode
    localparam logic [1:0] HIGH_ADDR = 2'(n);
    assign rs1_high_select[n] = (rs1_addr[4:3] == HIGH_ADDR);
    assign rs2_high_select[n] = (rs2_addr[4:3] == HIGH_ADDR);
    assign write_high_select[n] = (w_addr[4:3] == HIGH_ADDR);
  end
  for (genvar r = 0; r < 32; r++) begin : g_read
    assign rs1_select[r] = rs1_high_select[r/8] && rs1_low_select[r%8];
    assign rs2_select[r] = rs2_high_select[r/8] && rs2_low_select[r%8];
    assign rs1_masked[r] = words[r] & {32{rs1_select[r]}};
    assign rs2_masked[r] = words[r] & {32{rs2_select[r]}};
  end
  for (genvar g = 0; g < 4; g++) begin : g_group
    assign rs1_group[g] =
        ((rs1_masked[g*8]   | rs1_masked[g*8+1]) |
         (rs1_masked[g*8+2] | rs1_masked[g*8+3])) |
        ((rs1_masked[g*8+4] | rs1_masked[g*8+5]) |
         (rs1_masked[g*8+6] | rs1_masked[g*8+7]));
    assign rs2_group[g] =
        ((rs2_masked[g*8]   | rs2_masked[g*8+1]) |
         (rs2_masked[g*8+2] | rs2_masked[g*8+3])) |
        ((rs2_masked[g*8+4] | rs2_masked[g*8+5]) |
         (rs2_masked[g*8+6] | rs2_masked[g*8+7]));
  end
  assign rs1_read = (rs1_group[0] | rs1_group[1]) | (rs1_group[2] | rs1_group[3]);
  assign rs2_read = (rs2_group[0] | rs2_group[1]) | (rs2_group[2] | rs2_group[3]);

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = rs1_read;

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = rs2_read;
  end

endmodule
