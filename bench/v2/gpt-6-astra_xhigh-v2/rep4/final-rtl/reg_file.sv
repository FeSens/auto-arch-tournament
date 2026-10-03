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
// Storage is 31 independent fabric words, synchronously reset to zero.
// Constant-index masked leaves feed balanced read trees; no RAM read port
// or x0 storage is inferred at the ID/EX operand-capture boundary.
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

  wire [31:0] rs1_tree [1:63];
  wire [31:0] rs2_tree [1:63];

  assign rs1_tree[32] = 32'b0;
  assign rs2_tree[32] = 32'b0;
  for (genvar i = 1; i < 32; i++) begin : g_word
    logic [31:0] word_q;
    wire rs1_select, rs2_select;
    always_ff @(posedge clock) begin
      if (reset) word_q <= 32'b0;
      else if (w_en && w_addr == 5'(i)) word_q <= w_data;
    end
    assign rs1_select = rs1_addr == 5'(i);
    assign rs2_select = rs2_addr == 5'(i);
    assign rs1_tree[32+i] = word_q & {32{rs1_select}};
    assign rs2_tree[32+i] = word_q & {32{rs2_select}};
  end
  for (genvar i = 1; i < 32; i++) begin : g_read_tree
    assign rs1_tree[i] = rs1_tree[2*i] | rs1_tree[2*i+1];
    assign rs2_tree[i] = rs2_tree[2*i] | rs2_tree[2*i+1];
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = rs1_tree[1];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = rs2_tree[1];
  end

endmodule
