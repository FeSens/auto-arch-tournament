// Architectural RF lookup and forwarding end at the OF/EX register.
module operand_stage (
  input logic clock, reset, stall, flush, accept,
  input id_of_t in,
  output logic [4:0] rs1_addr, rs2_addr,
  input logic [31:0] rs1_data, rs2_data,
  input logic [4:0] ex_rd, mem_rd, wb_rd,
  input logic ex_w_en, ex_normal_w_en, ex_load, mem_w_en, wb_w_en,
  input logic [31:0] ex_result, ex_normal_result, mem_result, wb_result,
  output logic load_use,
  output id_ex_t out
);
  logic [1:0] sel1, sel2;
  logic [31:0] value1, value2;
  id_ex_t reg_q;
  assign rs1_addr = in.rs1_addr;
  assign rs2_addr = in.rs2_addr;
  assign load_use = in.valid && ex_load && ex_rd != 0 &&
    ((in.use_rs1 && in.rs1_addr == ex_rd) ||
     (in.use_rs2 && in.rs2_addr == ex_rd));
  forward_unit u_fwd (
    .rs1_addr(in.rs1_addr), .rs2_addr(in.rs2_addr),
    .ex_rd(ex_rd), .mem_rd(mem_rd), .wb_rd(wb_rd),
    .ex_w_en(ex_w_en), .mem_w_en(mem_w_en), .wb_w_en(wb_w_en),
    .fwd_rs1(sel1), .fwd_rs2(sel2)
  );
  always_comb begin
    // Resolve normal EX and completed DIV as separate one-hot data terms.
    // This removes a cascaded wide EX-result mux before OF capture.
    value1 = ({32{sel1 == 1 && ex_normal_w_en}} & ex_normal_result) |
             ({32{sel1 == 1 && !ex_normal_w_en}} & ex_result) |
             ({32{sel1 == 2}} & mem_result) |
             ({32{sel1 == 3}} & wb_result) |
             ({32{sel1 == 0}} & rs1_data);
    value2 = ({32{sel2 == 1 && ex_normal_w_en}} & ex_normal_result) |
             ({32{sel2 == 1 && !ex_normal_w_en}} & ex_result) |
             ({32{sel2 == 2}} & mem_result) |
             ({32{sel2 == 3}} & wb_result) |
             ({32{sel2 == 0}} & rs2_data);
  end
  always_ff @(posedge clock) begin
    if (reset) reg_q <= '0;
    else begin
      if (flush) reg_q.valid <= 1'b0;
      else if (!stall) reg_q.valid <= accept && in.valid;
      if (accept && in.valid && !stall && !flush) begin
        reg_q.pc <= in.pc;
        reg_q.imm <= in.imm;
        reg_q.rd <= in.rd;
        reg_q.rs1_addr <= in.rs1_addr;
        reg_q.rs2_addr <= in.rs2_addr;
        reg_q.rs1_val <= in.rs1_addr == 0 ? 0 : value1;
        reg_q.rs2_val <= in.rs2_addr == 0 ? 0 : value2;
        reg_q.ctrl <= in.ctrl;
        reg_q.instr <= in.instr;
        reg_q.predicted_taken <= in.predicted_taken;
      end
    end
  end
  assign out = reg_q;
endmodule
