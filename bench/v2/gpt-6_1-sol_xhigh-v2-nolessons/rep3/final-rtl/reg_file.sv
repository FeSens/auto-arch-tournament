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
// Each writable word has its own resettable flops and constant-address
// write enable. Each read port selects within four eight-word groups,
// then selects the group. These are mux partitions, with no bank conflicts.
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

  // Only constant-index wires assemble the read network; storage is never
  // described as an array with a variable-index write or read.
  wire [31:0] words [0:31];
  assign words[0] = 32'b0;

  for (genvar r = 1; r < 32; r++) begin : gen_regs
    localparam logic [4:0] ADDR = 5'(r);
    logic [31:0] value_q;

    always_ff @(posedge clock) begin
      if (reset)
        value_q <= 32'b0;
      else if (w_en && w_addr == ADDR)
        value_q <= w_data;
    end
    assign words[r] = value_q;
  end

  wire [31:0] rs1_groups [0:3];
  wire [31:0] rs2_groups [0:3];
  logic [31:0] rs1_read, rs2_read;

  for (genvar g = 0; g < 4; g++) begin : gen_read_groups
    assign rs1_groups[g] =
        ({32{rs1_addr[2:0] == 3'd0}} & words[g*8 + 0])
      | ({32{rs1_addr[2:0] == 3'd1}} & words[g*8 + 1])
      | ({32{rs1_addr[2:0] == 3'd2}} & words[g*8 + 2])
      | ({32{rs1_addr[2:0] == 3'd3}} & words[g*8 + 3])
      | ({32{rs1_addr[2:0] == 3'd4}} & words[g*8 + 4])
      | ({32{rs1_addr[2:0] == 3'd5}} & words[g*8 + 5])
      | ({32{rs1_addr[2:0] == 3'd6}} & words[g*8 + 6])
      | ({32{rs1_addr[2:0] == 3'd7}} & words[g*8 + 7]);
    assign rs2_groups[g] =
        ({32{rs2_addr[2:0] == 3'd0}} & words[g*8 + 0])
      | ({32{rs2_addr[2:0] == 3'd1}} & words[g*8 + 1])
      | ({32{rs2_addr[2:0] == 3'd2}} & words[g*8 + 2])
      | ({32{rs2_addr[2:0] == 3'd3}} & words[g*8 + 3])
      | ({32{rs2_addr[2:0] == 3'd4}} & words[g*8 + 4])
      | ({32{rs2_addr[2:0] == 3'd5}} & words[g*8 + 5])
      | ({32{rs2_addr[2:0] == 3'd6}} & words[g*8 + 6])
      | ({32{rs2_addr[2:0] == 3'd7}} & words[g*8 + 7]);
  end

  always_comb begin
    case (rs1_addr[4:3])
      2'd0:    rs1_read = rs1_groups[0];
      2'd1:    rs1_read = rs1_groups[1];
      2'd2:    rs1_read = rs1_groups[2];
      default: rs1_read = rs1_groups[3];
    endcase
    case (rs2_addr[4:3])
      2'd0:    rs2_read = rs2_groups[0];
      2'd1:    rs2_read = rs2_groups[1];
      2'd2:    rs2_read = rs2_groups[2];
      default: rs2_read = rs2_groups[3];
    endcase

    // WB write-first bypass is independent of reset, as before. x0 has
    // priority even when the write port targets zero with nonzero data.
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
