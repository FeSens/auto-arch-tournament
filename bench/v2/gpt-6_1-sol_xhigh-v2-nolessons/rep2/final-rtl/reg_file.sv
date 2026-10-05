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
// Constant-index flop words and masked, balanced read trees keep register
// access before the ID/EX operand flops, rather than inferring a RAM whose
// synchronous read could absorb that execute-stage launch boundary.
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

  for (genvar r = 1; r < 32; r++) begin : g_word
    localparam logic [4:0] WORD_ADDR = 5'(r);
    logic [31:0] word_q;
    wire write_en = w_en && (w_addr == WORD_ADDR);
    wire rs1_match = (rs1_addr == WORD_ADDR);
    wire rs2_match = (rs2_addr == WORD_ADDR);

    always_ff @(posedge clock) begin
      if (reset) word_q <= 32'b0;
      else if (write_en) word_q <= w_data;
    end

    assign rs1_tree[32+r] = word_q & {32{rs1_match}};
    assign rs2_tree[32+r] = word_q & {32{rs2_match}};
  end

  for (genvar n = 1; n < 32; n++) begin : g_read_tree
    assign rs1_tree[n] = rs1_tree[2*n] | rs1_tree[2*n+1];
    assign rs2_tree[n] = rs2_tree[2*n] | rs2_tree[2*n+1];
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
