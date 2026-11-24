// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero (writes silently dropped).
//   - Two combinational read ports.
//   - Single synchronous write port.
//   - Default reads return zero for x0 and bypass same-cycle writes.
//   - Raw reads expose stored data and nonzero flags so the core can
//     select WB collisions and mask x0 in the execute operand mux.
//
// Two 16-word LUT-RAM banks keep the asynchronous reads ahead of the
// fabric ID/EX operand registers. Reset clears the written bits, which
// mask unwritten entries and any stale contents left in the banks.
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata, rd_wdata.
module reg_file #(
  parameter bit RAW_READ = 1'b0
) (
  input  logic        clock,
  input  logic        reset,

  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data,
  output logic        rs1_nonzero,
  output logic        rs2_nonzero
);

  (* syn_ramstyle = "distributed_ram" *) logic [31:0] regs_lo [0:15];
  (* syn_ramstyle = "distributed_ram" *) logic [31:0] regs_hi [0:15];
  logic [15:0] written_lo_q, written_hi_q;
  logic write_lo, write_hi;

  assign write_lo = !reset && w_en && !w_addr[4] && w_addr[3:0] != 4'b0;
  assign write_hi = !reset && w_en && w_addr[4];

  always_ff @(posedge clock) begin
    if (write_lo) regs_lo[w_addr[3:0]] <= w_data;
    if (write_hi) regs_hi[w_addr[3:0]] <= w_data;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      written_lo_q <= '0;
      written_hi_q <= '0;
    end else begin
      if (write_lo) written_lo_q[w_addr[3:0]] <= 1'b1;
      if (write_hi) written_hi_q[w_addr[3:0]] <= 1'b1;
    end
  end

  logic [31:0] rs1_stored, rs2_stored;
  logic rs1_lo, rs1_hi, rs2_lo, rs2_hi;

  // Select the valid bank in parallel with the RAM reads. Bit zero of
  // the lower bank's bitmap stays clear, hardwiring x0 to zero.
  assign rs1_lo = !rs1_addr[4] && written_lo_q[rs1_addr[3:0]];
  assign rs1_hi =  rs1_addr[4] && written_hi_q[rs1_addr[3:0]];
  assign rs2_lo = !rs2_addr[4] && written_lo_q[rs2_addr[3:0]];
  assign rs2_hi =  rs2_addr[4] && written_hi_q[rs2_addr[3:0]];
  assign rs1_stored = ({32{rs1_lo}} & regs_lo[rs1_addr[3:0]])
                   | ({32{rs1_hi}} & regs_hi[rs1_addr[3:0]]);
  assign rs2_stored = ({32{rs2_lo}} & regs_lo[rs2_addr[3:0]])
                   | ({32{rs2_hi}} & regs_hi[rs2_addr[3:0]]);
  assign rs1_nonzero = rs1_addr != 5'b0;
  assign rs2_nonzero = rs2_addr != 5'b0;

  if (RAW_READ) begin : gen_raw_read
    assign rs1_data = rs1_stored;
    assign rs2_data = rs2_stored;
  end else begin : gen_write_first
    assign rs1_data = rs1_nonzero && w_en && w_addr == rs1_addr ? w_data : rs1_stored;
    assign rs2_data = rs2_nonzero && w_en && w_addr == rs2_addr ? w_data : rs2_stored;
  end

endmodule
