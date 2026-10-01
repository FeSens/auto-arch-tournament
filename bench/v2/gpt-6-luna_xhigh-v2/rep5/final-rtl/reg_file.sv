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
// The reset clears all 32 registers. Distributed-LUT or flop inference is
// fine here; explicit BRAM attribution lives on the larger imem/dmem
// declarations in soc.sv (phase 5).
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

  logic [31:0] regs [0:31];

  // Decode each asynchronous read address once, then select register data
  // with masked terms. The reduction is explicitly staged so the read path
  // has a balanced OR tree instead of an inferred 32:1 indexed mux.
  logic [31:1] rs1_select;
  logic [31:1] rs2_select;
  logic [31:0] rs1_terms [0:31];
  logic [31:0] rs2_terms [0:31];
  logic [31:0] rs1_or_l1 [0:15];
  logic [31:0] rs2_or_l1 [0:15];
  logic [31:0] rs1_or_l2 [0:7];
  logic [31:0] rs2_or_l2 [0:7];
  logic [31:0] rs1_or_l3 [0:3];
  logic [31:0] rs2_or_l3 [0:3];
  logic [31:0] rs1_or_l4 [0:1];
  logic [31:0] rs2_or_l4 [0:1];
  logic [31:0] rs1_read;
  logic [31:0] rs2_read;

  genvar g;
  generate
    for (g = 0; g < 32; g = g + 1) begin : gen_read_terms
      localparam logic [4:0] REG_INDEX = g;

      if (g == 0) begin : gen_x0
        assign rs1_terms[g] = 32'b0;
        assign rs2_terms[g] = 32'b0;
      end else begin : gen_nonzero
        assign rs1_select[g] = (rs1_addr == REG_INDEX);
        assign rs2_select[g] = (rs2_addr == REG_INDEX);
        assign rs1_terms[g] = regs[g] & {32{rs1_select[g]}};
        assign rs2_terms[g] = regs[g] & {32{rs2_select[g]}};
      end
    end

    for (g = 0; g < 16; g = g + 1) begin : gen_or_l1
      assign rs1_or_l1[g] = rs1_terms[2*g] | rs1_terms[2*g+1];
      assign rs2_or_l1[g] = rs2_terms[2*g] | rs2_terms[2*g+1];
    end
    for (g = 0; g < 8; g = g + 1) begin : gen_or_l2
      assign rs1_or_l2[g] = rs1_or_l1[2*g] | rs1_or_l1[2*g+1];
      assign rs2_or_l2[g] = rs2_or_l1[2*g] | rs2_or_l1[2*g+1];
    end
    for (g = 0; g < 4; g = g + 1) begin : gen_or_l3
      assign rs1_or_l3[g] = rs1_or_l2[2*g] | rs1_or_l2[2*g+1];
      assign rs2_or_l3[g] = rs2_or_l2[2*g] | rs2_or_l2[2*g+1];
    end
    for (g = 0; g < 2; g = g + 1) begin : gen_or_l4
      assign rs1_or_l4[g] = rs1_or_l3[2*g] | rs1_or_l3[2*g+1];
      assign rs2_or_l4[g] = rs2_or_l3[2*g] | rs2_or_l3[2*g+1];
    end
  endgenerate

  assign rs1_read = rs1_or_l4[0] | rs1_or_l4[1];
  assign rs2_read = rs2_or_l4[0] | rs2_or_l4[1];

  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) regs[i] <= 32'b0;
    end else if (w_en && w_addr != 5'b0) begin
      regs[w_addr] <= w_data;
    end
  end

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
