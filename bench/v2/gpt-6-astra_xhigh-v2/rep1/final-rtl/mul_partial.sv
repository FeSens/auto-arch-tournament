// EX: four DSP-sized signed products, with no reconstruction on this side
// of EX/MEM. Low limbs are unsigned for every RV32M multiply variant.
module mul_partial (
  input  logic [4:0]   op,
  input  logic [31:0]  a,
  input  logic [31:0]  b,
  output logic [135:0] partials
);
  logic signed [16:0] al, ah, bl, bh;
  logic signed [33:0] ll, lh, hl, hh;

  assign al = $signed({1'b0, a[15:0]});
  assign bl = $signed({1'b0, b[15:0]});
  assign ah = $signed({a[31] && (op == ALU_MULH || op == ALU_MULHSU), a[31:16]});
  assign bh = $signed({b[31] && (op == ALU_MULH), b[31:16]});
  assign ll = al * bl;
  assign lh = al * bh;
  assign hl = ah * bl;
  assign hh = ah * bh;
  assign partials = {ll, lh, hl, hh};
endmodule
