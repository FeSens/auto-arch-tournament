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
// Each stored word is a separate resettable flop bank. Constant-index
// leaves and five balanced OR levels keep the reads combinational and
// prevent a RAM read port from absorbing the ID/EX operand registers.
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

  logic [31:1] rs1_onehot, rs2_onehot;
  wire [31:0] rs1_tree [0:62];
  wire [31:0] rs2_tree [0:62];

  for (genvar i = 1; i < 32; i++) begin : g_read_decode
    assign rs1_onehot[i] = rs1_addr == 5'(i);
    assign rs2_onehot[i] = rs2_addr == 5'(i);
  end

  // x0 has no storage or write enable.
  assign rs1_tree[31] = 32'b0;
  assign rs2_tree[31] = 32'b0;
  for (genvar i = 1; i < 32; i++) begin : g_word
    logic [31:0] word_q;
    always_ff @(posedge clock) begin
      if (reset) word_q <= 32'b0;
      else if (w_en && w_addr == 5'(i)) word_q <= w_data;
    end
    assign rs1_tree[31+i] = word_q & {32{rs1_onehot[i]}};
    assign rs2_tree[31+i] = word_q & {32{rs2_onehot[i]}};
  end

  // Heap indexing gives 32 leaves and exactly five binary reduction
  // levels (nodes 15..30, 7..14, 3..6, 1..2, then root 0).
  for (genvar i = 0; i < 31; i++) begin : g_read_tree
    assign rs1_tree[i] = rs1_tree[2*i+1] | rs1_tree[2*i+2];
    assign rs2_tree[i] = rs2_tree[2*i+1] | rs2_tree[2*i+2];
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = rs1_tree[0];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = rs2_tree[0];
  end

endmodule
