// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file on distributed LUT-RAM.
//   - x0 hardwired to zero: reads are masked with (addr != 0), so entry 0 of
//     the RAM may hold anything (writes to x0 are harmless and not gated).
//   - Two combinational (asynchronous) read ports.
//   - Single synchronous write port; a same-cycle read returns the OLD value
//     (BYPASS = 0). The core writes the regfile from the MEM stage and covers
//     the instruction in MEM with the m2 bypass in ID.
//   - BYPASS = 1 adds a post-read write-first mux (a same-cycle write to the
//     read address returns the new value).
//
// Structure: each read port owns a private copy of the array, built from
// explicit 16-entry x 4-bit slices that match the Gowin RAM16SDP4 primitive
// (async read, sync write): per port, 2 halves (entry = {half, addr[3:0]})
// x 8 nibbles = 16 slices, 32 for both ports. Read data is a 2:1 half select
// by addr[4] ANDed with the x0 mask: one LUT4 {lo, hi, a4, nonzero} per bit,
// with the nonzero detect in parallel with the RAM read. The write data net
// has fan-out 2 per bit (one data pin per port copy) and the write decode is
// a 2-way half select feeding the slice write enables.
//
// The array is deliberately built from 16x4 slices, not one `regs[0:31]`
// array: a 32x32 unpacked array is inferred as a synchronous-read BSRAM and
// the synthesizer slides the ID/EX rs1_val/rs2_val flops into it, dragging
// the BSRAM clock-to-out into the EX cycle. The slices are below any BSRAM
// threshold and carry syn_ramstyle = "distributed_ram".
//
// The RAM has no reset: registers power up as whatever the RAM holds (zero
// in simulation, symbolic in formal). Software and the riscv-formal reg check
// only ever observe values that were written first.
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata, rd_wdata.
module reg_file #(
  // 1: write-first bypass (a same-cycle write to the read address returns
  //    the new value). 0: plain read; the core writes the regfile from the
  //    MEM stage (one cycle early) so ID never needs the WB-stage bypass.
  parameter bit BYPASS = 1'b1
) (
  input  logic        clock,
  // The RAM cannot be reset; kept so the port list is unchanged.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        reset,
  /* verilator lint_on UNUSEDSIGNAL */

  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  // Async read of the low (entry 0..15) and high (entry 16..31) half, per
  // read port.
  logic [31:0] rd1_lo, rd1_hi;
  logic [31:0] rd2_lo, rd2_hi;

`ifdef RISCV_FORMAL
  // Formal model only (riscv-formal defines RISCV_FORMAL; synthesis and
  // simulation never do). Same behaviour as the LUT-RAM slices below (async
  // read, sync write, no reset, same half split / x0 mask downstream), but
  // built from plain 32-bit flop words: 64 SMT arrays with 20 deep store
  // chains made the `reg` check take far longer than the rest of the suite
  // (> 6 min vs ~10 s per check), while this model finishes in ~1 min. The
  // RAM slice mapping itself is covered by test_reg_file.py and cosim.
  logic [1023:0] flat;
  for (genvar i = 0; i < 32; i++) begin : g_f
    logic [31:0] q;
    always_ff @(posedge clock) if (w_en && w_addr == i[4:0]) q <= w_data;
    assign flat[i*32 +: 32] = q;
  end
  assign rd1_lo = flat[{1'b0, rs1_addr[3:0], 5'b0} +: 32];
  assign rd1_hi = flat[{1'b1, rs1_addr[3:0], 5'b0} +: 32];
  assign rd2_lo = flat[{1'b0, rs2_addr[3:0], 5'b0} +: 32];
  assign rd2_hi = flat[{1'b1, rs2_addr[3:0], 5'b0} +: 32];
`else
  for (genvar h = 0; h < 2; h++) begin : g_half
    // Write-enable of this half; the low 4 address bits index the slice.
    logic we_h;
    assign we_h = w_en && (w_addr[4] == h[0]);

    for (genvar n = 0; n < 8; n++) begin : g_nib
      (* syn_ramstyle = "distributed_ram" *) logic [3:0] m1 [0:15];
      (* syn_ramstyle = "distributed_ram" *) logic [3:0] m2 [0:15];

      always_ff @(posedge clock) begin
        if (we_h) begin
          m1[w_addr[3:0]] <= w_data[4*n +: 4];
          m2[w_addr[3:0]] <= w_data[4*n +: 4];
        end
      end

      if (h == 0) begin : g_lo
        assign rd1_lo[4*n +: 4] = m1[rs1_addr[3:0]];
        assign rd2_lo[4*n +: 4] = m2[rs2_addr[3:0]];
      end else begin : g_hi
        assign rd1_hi[4*n +: 4] = m1[rs1_addr[3:0]];
        assign rd2_hi[4*n +: 4] = m2[rs2_addr[3:0]];
      end
    end
  end
`endif

  logic nz1, nz2;

  always_comb begin
    nz1 = (rs1_addr != 5'b0);
    nz2 = (rs2_addr != 5'b0);

    // Half select + x0 mask (one LUT4 per bit).
    rs1_data = (rs1_addr[4] ? rd1_hi : rd1_lo) & {32{nz1}};
    rs2_data = (rs2_addr[4] ? rd2_hi : rd2_lo) & {32{nz2}};

    if (BYPASS) begin
      if (w_en && nz1 && w_addr == rs1_addr)
        rs1_data = w_data;
      if (w_en && nz2 && w_addr == rs2_addr)
        rs2_data = w_data;
    end
  end

endmodule
