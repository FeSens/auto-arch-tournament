// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file.
//   - x0 hardwired to zero: it is a constant, not a flop (flops exist for
//     x1..x31 only), so a read of x0 needs no `addr == 0` gate and x0 does
//     not depend on reset.
//   - Two plain combinational read ports: rs?_data = regs[rs?_addr]. There is
//     NO write-first bypass: a write becomes visible on the cycle after the
//     edge that captures it. core.sv drives the write port from the MEM
//     stage, so an instruction that is in WB in cycle t has already been
//     written by the end of cycle t-1 and the ID stage reads it straight
//     from here (the P3 case needs no compare / mux).
//   - Single synchronous write port. A write to x0 is dropped.
//
// The reset clears x1..x31. Plain flops (no RAM inference).
//
// Latency:        write = 1 cycle (synchronous), read = combinational.
// RVFI fields:    feeds rs1_rdata, rs2_rdata (via the ID bypass / ID/EX).
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

  // Flops for x1..x31 (element i-1 holds x_i).
  logic [30:0][31:0] regs_q;

  for (genvar i = 1; i < 32; i++) begin : g_reg
    always_ff @(posedge clock) begin
      if (reset)                         regs_q[i-1] <= 32'b0;
      else if (w_en && w_addr == 5'(i))  regs_q[i-1] <= w_data;
    end
  end

  // Read view: element 0 is the constant x0.
  logic [31:0][31:0] regs_v;
  assign regs_v = {regs_q, 32'b0};

  assign rs1_data = regs_v[rs1_addr];
  assign rs2_data = regs_v[rs2_addr];

endmodule
