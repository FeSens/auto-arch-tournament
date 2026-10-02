// rtl/icache.sv
//
// 2048-word direct-mapped instruction cache used only as an imem-stall
// filler. One BSRAM-style array holds {valid, tag = pc[19:13], word} per
// entry (index = pc[12:2]); instruction memory is bounded to [0, 1 MB), so a
// 7-bit tag is exact for every architecturally reachable pc.
//
// Write port : driven by registered ID/EX flops (pc, instr) of valid,
//              non-squashed instructions, never by raw imem_data. The memory
//              is read-only for the workload (no self-modifying code), so a
//              repeated or late write of the same pc stores the same word.
// Read port  : flop-addressed (the caller passes pc+4), registered output,
//              read enable = the caller's accept, so the output register
//              holds the entry for the *current* pc whenever the last
//              accepted word fell through.
//
// The array has no reset; the valid bit is cleared by an initial block
// (BSRAM power-up image). Read-during-write returns the old entry; because
// valid / tag / word live in one array the read is always self-consistent.
module icache (
  input  logic        clock,
  // write port (registered sources)
  input  logic        wr_en,
  input  logic [10:0] wr_idx,
  input  logic [6:0]  wr_tag,
  input  logic [31:0] wr_data,
  // read port (registered output)
  input  logic        rd_en,
  input  logic [10:0] rd_idx,
  output logic [31:0] rd_data,
  output logic        rd_valid,
  output logic [6:0]  rd_tag
);

  logic [39:0] mem [0:2047];
  logic [39:0] dout_q;

  // Two half-size loops: the Gowin synthesiser's loop limit is 2000 iterations.
  initial begin
    for (int i = 0; i < 1024; i++) mem[i]        = 40'b0;
    for (int i = 0; i < 1024; i++) mem[1024 + i] = 40'b0;
    dout_q = 40'b0;
  end

  always_ff @(posedge clock) begin
    if (wr_en) mem[wr_idx] <= {1'b1, wr_tag, wr_data};
    if (rd_en) dout_q      <= mem[rd_idx];
  end

  assign rd_data  = dout_q[31:0];
  assign rd_tag   = dout_q[38:32];
  assign rd_valid = dout_q[39];

endmodule
