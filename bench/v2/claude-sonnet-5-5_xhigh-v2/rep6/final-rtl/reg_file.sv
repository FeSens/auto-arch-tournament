// rtl/reg_file.sv
//
// 32 x 32 RV32I integer register file, built from explicit fabric flops.
//   - x0 hardwired to zero (not stored; reads always 0).
//   - Two combinational read ports (32:1 mux trees over a packed vector).
//   - Single synchronous write port, one-hot per-register write enable.
//   - Write-first bypass: a same-cycle write to the read address returns
//     the new value. This matches the prior Chisel core's RegFile.scala
//     and lets the ID stage see WB-stage writes within the same cycle
//     without an extra forwarding mux.
//
// Each register is its own named flop vector (generate loop) rather than an
// unpacked memory array, so synthesis cannot infer a block RAM for it. A
// BSRAM here would absorb the ID/EX operand registers and make every EX
// path launch from the RAM output (tC2Q ~2.3 ns) instead of a fabric flop.
//
// The reset clears all 31 stored registers.
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
  // Raw (bypass-free) read data plus the write-first match flags, for a
  // consumer that folds the bypass into its own operand mux (id_stage).
  output logic [31:0] rs1_raw,
  output logic [31:0] rs2_raw,
  output logic        rs1_byp,
  output logic        rs2_byp,

  input  logic        w_en,
  input  logic [4:0]  w_addr,
  input  logic [31:0] w_data
);

  // Packed register image; slot 0 is x0 and is tied to zero.
  logic [32*32-1:0] rf;
  assign rf[31:0] = 32'b0;

  logic w_nz;   // write to a real register (x0 writes are dropped)
  assign w_nz = w_en && (w_addr != 5'b0);

  for (genvar i = 1; i < 32; i++) begin : g_reg
    (* syn_ramstyle = "registers" *) logic [31:0] r_q;
    logic we;
    assign we = w_nz && (w_addr == 5'(i));

    always_ff @(posedge clock) begin
      if (reset)   r_q <= 32'b0;
      else if (we) r_q <= w_data;
    end

    assign rf[i*32 +: 32] = r_q;
  end

  // Read ports: x0 reads 0 through the tied-off slot; a same-cycle write to
  // a non-zero read address is bypassed.
  always_comb begin
    rs1_raw  = rf[rs1_addr*32 +: 32];
    rs2_raw  = rf[rs2_addr*32 +: 32];
    rs1_byp  = w_nz && (w_addr == rs1_addr);
    rs2_byp  = w_nz && (w_addr == rs2_addr);

    rs1_data = rs1_byp ? w_data : rs1_raw;
    rs2_data = rs2_byp ? w_data : rs2_raw;
  end

endmodule
