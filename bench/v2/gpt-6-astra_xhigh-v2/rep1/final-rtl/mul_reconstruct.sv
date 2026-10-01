// MEM: reconstruct modulo 2^64 from the registered {LL,LH,HL,HH}.
// Two carry-save compressors leave exactly one carry-propagating addition.
module mul_reconstruct (
  input  logic [135:0] partials,
  output logic [63:0] product
);
  logic [33:0] ll, lh, hl;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [33:0] hh; // top two bits vanish in the modulo-2^64 shift
  /* verilator lint_on UNUSEDSIGNAL */
  logic [63:0] x, y, z, w;
  logic [63:0] s1, c1, s2, c2;

  assign {ll, lh, hl, hh} = partials;
  assign x = {{30{ll[33]}}, ll};
  assign y = {{14{lh[33]}}, lh, 16'b0};
  assign z = {{14{hl[33]}}, hl, 16'b0};
  assign w = {hh[31:0], 32'b0};
  assign s1 = x ^ y ^ z;
  assign c1 = ((x & y) | (x & z) | (y & z)) << 1;
  assign s2 = s1 ^ c1 ^ w;
  assign c2 = ((s1 & c1) | (s1 & w) | (c1 & w)) << 1;
  assign product = s2 + c2;
endmodule
