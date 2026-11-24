// Conservative Q1.12 reciprocals for Q0.32 divisors in [0.5, 1).
module div_seed_rom (
  input  logic        clock,
  input  logic        read_en,
  input  logic [9:0]  addr,
  output logic [12:0] seed
);
  (* syn_romstyle = "block_rom" *) logic [12:0] seeds [0:1023];

  // The leading one is implicit in addr. Using the upper end of each
  // interval and rounding down keeps the scaled divisor at most one.
  initial begin
    for (int addr_index = 0; addr_index < 1024; addr_index++) begin
      seeds[addr_index] = 13'((1 << 23) / (1025 + addr_index));
    end
  end

  always_ff @(posedge clock) begin
    if (read_en) seed <= seeds[addr];
  end
endmodule
