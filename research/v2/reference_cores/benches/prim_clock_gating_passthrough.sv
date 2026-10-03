// FPGA pass-through clock gate for Ibex (as in Ibex's FPGA examples, minus
// the BUFGCE): the core clock is never gated in the Fmax bench.
module prim_clock_gating #(
  parameter bit NoFpgaGate = 1'b0,
  parameter bit FpgaBufGlobal = 1'b1
) (
  input  logic clk_i,
  input  logic en_i,
  input  logic test_en_i,
  output logic clk_o
);
  assign clk_o = clk_i;
endmodule
