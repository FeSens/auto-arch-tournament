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
// Each architectural word is an explicit resettable scalar flop word.
// Complete case reads and both WB bypasses finish before ID/EX captures
// its operands; there is no inferred RF memory or later bank selection.
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

  logic [31:0] x1_q;
  logic [31:0] x2_q;
  logic [31:0] x3_q;
  logic [31:0] x4_q;
  logic [31:0] x5_q;
  logic [31:0] x6_q;
  logic [31:0] x7_q;
  logic [31:0] x8_q;
  logic [31:0] x9_q;
  logic [31:0] x10_q;
  logic [31:0] x11_q;
  logic [31:0] x12_q;
  logic [31:0] x13_q;
  logic [31:0] x14_q;
  logic [31:0] x15_q;
  logic [31:0] x16_q;
  logic [31:0] x17_q;
  logic [31:0] x18_q;
  logic [31:0] x19_q;
  logic [31:0] x20_q;
  logic [31:0] x21_q;
  logic [31:0] x22_q;
  logic [31:0] x23_q;
  logic [31:0] x24_q;
  logic [31:0] x25_q;
  logic [31:0] x26_q;
  logic [31:0] x27_q;
  logic [31:0] x28_q;
  logic [31:0] x29_q;
  logic [31:0] x30_q;
  logic [31:0] x31_q;

  always_ff @(posedge clock) begin
    if (reset) x1_q <= 32'b0;
    else if (w_en && w_addr == 5'd1) x1_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x2_q <= 32'b0;
    else if (w_en && w_addr == 5'd2) x2_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x3_q <= 32'b0;
    else if (w_en && w_addr == 5'd3) x3_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x4_q <= 32'b0;
    else if (w_en && w_addr == 5'd4) x4_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x5_q <= 32'b0;
    else if (w_en && w_addr == 5'd5) x5_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x6_q <= 32'b0;
    else if (w_en && w_addr == 5'd6) x6_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x7_q <= 32'b0;
    else if (w_en && w_addr == 5'd7) x7_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x8_q <= 32'b0;
    else if (w_en && w_addr == 5'd8) x8_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x9_q <= 32'b0;
    else if (w_en && w_addr == 5'd9) x9_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x10_q <= 32'b0;
    else if (w_en && w_addr == 5'd10) x10_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x11_q <= 32'b0;
    else if (w_en && w_addr == 5'd11) x11_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x12_q <= 32'b0;
    else if (w_en && w_addr == 5'd12) x12_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x13_q <= 32'b0;
    else if (w_en && w_addr == 5'd13) x13_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x14_q <= 32'b0;
    else if (w_en && w_addr == 5'd14) x14_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x15_q <= 32'b0;
    else if (w_en && w_addr == 5'd15) x15_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x16_q <= 32'b0;
    else if (w_en && w_addr == 5'd16) x16_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x17_q <= 32'b0;
    else if (w_en && w_addr == 5'd17) x17_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x18_q <= 32'b0;
    else if (w_en && w_addr == 5'd18) x18_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x19_q <= 32'b0;
    else if (w_en && w_addr == 5'd19) x19_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x20_q <= 32'b0;
    else if (w_en && w_addr == 5'd20) x20_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x21_q <= 32'b0;
    else if (w_en && w_addr == 5'd21) x21_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x22_q <= 32'b0;
    else if (w_en && w_addr == 5'd22) x22_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x23_q <= 32'b0;
    else if (w_en && w_addr == 5'd23) x23_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x24_q <= 32'b0;
    else if (w_en && w_addr == 5'd24) x24_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x25_q <= 32'b0;
    else if (w_en && w_addr == 5'd25) x25_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x26_q <= 32'b0;
    else if (w_en && w_addr == 5'd26) x26_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x27_q <= 32'b0;
    else if (w_en && w_addr == 5'd27) x27_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x28_q <= 32'b0;
    else if (w_en && w_addr == 5'd28) x28_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x29_q <= 32'b0;
    else if (w_en && w_addr == 5'd29) x29_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x30_q <= 32'b0;
    else if (w_en && w_addr == 5'd30) x30_q <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) x31_q <= 32'b0;
    else if (w_en && w_addr == 5'd31) x31_q <= w_data;
  end

  always_comb begin
    case (rs1_addr)
      5'd0: rs1_data = 32'b0;
      5'd1: rs1_data = x1_q;
      5'd2: rs1_data = x2_q;
      5'd3: rs1_data = x3_q;
      5'd4: rs1_data = x4_q;
      5'd5: rs1_data = x5_q;
      5'd6: rs1_data = x6_q;
      5'd7: rs1_data = x7_q;
      5'd8: rs1_data = x8_q;
      5'd9: rs1_data = x9_q;
      5'd10: rs1_data = x10_q;
      5'd11: rs1_data = x11_q;
      5'd12: rs1_data = x12_q;
      5'd13: rs1_data = x13_q;
      5'd14: rs1_data = x14_q;
      5'd15: rs1_data = x15_q;
      5'd16: rs1_data = x16_q;
      5'd17: rs1_data = x17_q;
      5'd18: rs1_data = x18_q;
      5'd19: rs1_data = x19_q;
      5'd20: rs1_data = x20_q;
      5'd21: rs1_data = x21_q;
      5'd22: rs1_data = x22_q;
      5'd23: rs1_data = x23_q;
      5'd24: rs1_data = x24_q;
      5'd25: rs1_data = x25_q;
      5'd26: rs1_data = x26_q;
      5'd27: rs1_data = x27_q;
      5'd28: rs1_data = x28_q;
      5'd29: rs1_data = x29_q;
      5'd30: rs1_data = x30_q;
      5'd31: rs1_data = x31_q;
      default: rs1_data = 32'b0;
    endcase
    if (rs1_addr != 5'b0 && w_en && w_addr == rs1_addr)
      rs1_data = w_data;

    case (rs2_addr)
      5'd0: rs2_data = 32'b0;
      5'd1: rs2_data = x1_q;
      5'd2: rs2_data = x2_q;
      5'd3: rs2_data = x3_q;
      5'd4: rs2_data = x4_q;
      5'd5: rs2_data = x5_q;
      5'd6: rs2_data = x6_q;
      5'd7: rs2_data = x7_q;
      5'd8: rs2_data = x8_q;
      5'd9: rs2_data = x9_q;
      5'd10: rs2_data = x10_q;
      5'd11: rs2_data = x11_q;
      5'd12: rs2_data = x12_q;
      5'd13: rs2_data = x13_q;
      5'd14: rs2_data = x14_q;
      5'd15: rs2_data = x15_q;
      5'd16: rs2_data = x16_q;
      5'd17: rs2_data = x17_q;
      5'd18: rs2_data = x18_q;
      5'd19: rs2_data = x19_q;
      5'd20: rs2_data = x20_q;
      5'd21: rs2_data = x21_q;
      5'd22: rs2_data = x22_q;
      5'd23: rs2_data = x23_q;
      5'd24: rs2_data = x24_q;
      5'd25: rs2_data = x25_q;
      5'd26: rs2_data = x26_q;
      5'd27: rs2_data = x27_q;
      5'd28: rs2_data = x28_q;
      5'd29: rs2_data = x29_q;
      5'd30: rs2_data = x30_q;
      5'd31: rs2_data = x31_q;
      default: rs2_data = 32'b0;
    endcase
    if (rs2_addr != 5'b0 && w_en && w_addr == rs2_addr)
      rs2_data = w_data;

  end

endmodule
