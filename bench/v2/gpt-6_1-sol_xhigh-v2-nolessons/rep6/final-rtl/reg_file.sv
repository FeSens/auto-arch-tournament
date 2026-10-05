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
// Each writable word is an individually declared flop register with a
// constant write destination. This prevents register-file BRAM inference
// and keeps ID/EX operand latches separate from memory output registers.
// Synchronous reset deterministically clears all writable words.
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
  assign words[0] = 32'b0;

  for (genvar word = 1; word < 32; word++) begin : g_regs
    localparam logic [4:0] WORD_ADDR = 5'(word);
    logic [31:0] value_q;
    wire write_word = w_en && (w_addr == WORD_ADDR);

    always_ff @(posedge clock) begin
      if (reset)           value_q <= 32'b0;
      else if (write_word) value_q <= w_data;
    end
    assign words[word] = value_q;
  end

  always_comb begin
    if (rs1_addr == 5'b0)
      rs1_data = 32'b0;
    else if (w_en && w_addr == rs1_addr)
      rs1_data = w_data;
    else
      rs1_data = words[rs1_addr];

    if (rs2_addr == 5'b0)
      rs2_data = 32'b0;
    else if (w_en && w_addr == rs2_addr)
      rs2_data = w_data;
    else
      rs2_data = words[rs2_addr];
  end

endmodule
