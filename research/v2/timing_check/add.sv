module core_bench(input logic clock, input logic reset, output logic led);
  logic [63:0] s; logic [31:0] a, b, q;
  always_ff @(posedge clock) begin
    if (reset) s <= 64'h0123456789abcdef;
    else s <= {s[62:0], s[63] ^ s[62] ^ s[60] ^ s[59]} ^ {32'b0, q};
    a <= s[31:0]; b <= s[63:32] | 32'h1;
    q <= a + b;
  end
  assign led = ^q;
endmodule
