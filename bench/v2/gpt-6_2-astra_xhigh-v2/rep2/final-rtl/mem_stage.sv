// Select M-extension results in MEM. EX/MEM already contains the serviced byte
// address, accepted read word and forwarding result for each load.
module mem_stage (
  input  logic    clock,
  input  logic    reset,
  input  logic    hold_wb,
  input  logic [31:0] div_result,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t in,
  /* verilator lint_on UNUSEDSIGNAL */
  output mem_wb_t out
);
  logic [31:0] product;
  mul_product u_product (
    .op  (in.ctrl.alu_op),
    .a   (in.rs1_val),
    .b   (in.rs2_val),
    .out (product)
  );

  logic [3:0] byte_mask;
  assign byte_mask = access_mask(in.ctrl.mem_width, in.mem_addr[1:0]);

  mem_wb_t reg_q;
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // Retire the previous slot once while preserving its forwarding data.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      // funct3[2] selects DIV/REM within the M encoding. A new divide can
      // issue on this very edge while MEM samples the previous result.
      reg_q.alu_result <= in.ctrl.late_result ? (in.instr[14] ? div_result : product)
                                              : in.alu_result;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.rs1_val;
      reg_q.rs2_val    <= in.rs2_val;
      reg_q.pc_next    <= in.pc_next;
      reg_q.mem_addr   <= (in.ctrl.mem_read || in.ctrl.mem_write)
                        ? {in.mem_addr[31:2], 2'b0} : 32'b0;
      reg_q.mem_rdata  <= in.mem_rdata;
      reg_q.mem_wdata  <= store_lanes(in.ctrl.mem_width, in.write_data);
      reg_q.mem_wmask  <= in.ctrl.mem_write ? byte_mask : 4'b0;
      reg_q.mem_rmask  <= in.ctrl.mem_read  ? byte_mask : 4'b0;
      reg_q.ctrl       <= in.ctrl;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid;
    end
  end

  assign out = reg_q;
endmodule
