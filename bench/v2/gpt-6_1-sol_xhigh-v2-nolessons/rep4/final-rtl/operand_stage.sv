`ifndef CORE_PKG_DEFINED
`include "core_pkg.sv"
`endif
// ID/OC remains occupied until both sources and the EX slot are ready.
// A blocked load/divider retains its authoritative producer slot until it
// supplies a value. Independently resolved sources are saved before older
// WB slots drain; they are never reselected while this instruction holds.
module operand_stage (
  input logic clock, reset,
  input logic hold_ex,
  input logic flush,
  /* verilator lint_off UNUSEDSIGNAL */
  input id_ex_t in,
  /* verilator lint_on UNUSEDSIGNAL */
  input logic [4:0] ex_rd, mem_rd, wb_rd,
  input logic ex_writer, mem_writer, wb_writer,
  input logic ex_ready, mem_ready,
  input logic [31:0] ex_value, mem_value, wb_value,
  output logic operands_ready,
  output logic advance,
  output oc_ex_t out
);
  logic rs1_ready, rs2_ready, rs1_ready_q, rs2_ready_q;
  logic [31:0] rs1_value, rs2_value, rs1_value_q, rs2_value_q;
  logic [4:0] rs1_select, rs2_select, alu_a_select, alu_b_select;
  logic [31:0] alu_a_value, alu_b_value;
  oc_ex_t reg_q;

  forward_unit u_forward (
    .rs1_addr(in.rs1_addr), .rs2_addr(in.rs2_addr),
    .rs1_saved(rs1_ready_q), .rs2_saved(rs2_ready_q),
    .ex_rd(ex_rd), .mem_rd(mem_rd), .wb_rd(wb_rd),
    .ex_writer(ex_writer), .mem_writer(mem_writer), .wb_writer(wb_writer),
    .ex_ready(ex_ready), .mem_ready(mem_ready),
    .rs1_ready(rs1_ready), .rs2_ready(rs2_ready),
    .rs1_select(rs1_select), .rs2_select(rs2_select)
  );
  // Architectural sources and retained values share a single candidate OR.
  // Saved-source selection is part of the enables, not a following data mux.
  assign rs1_value = ({32{rs1_select[4]}} & rs1_value_q) |
                     ({32{rs1_select[3]}} & ex_value) |
                     ({32{rs1_select[2]}} & mem_value) |
                     ({32{rs1_select[1]}} & wb_value) |
                     ({32{rs1_select[0]}} & in.rs1_val);
  assign rs2_value = ({32{rs2_select[4]}} & rs2_value_q) |
                     ({32{rs2_select[3]}} & ex_value) |
                     ({32{rs2_select[2]}} & mem_value) |
                     ({32{rs2_select[1]}} & wb_value) |
                     ({32{rs2_select[0]}} & in.rs2_val);

  // Absorb PC/immediate selection into the scalar enables. These parallel
  // networks read candidate data directly, without the architectural OR.
  assign alu_a_select = rs1_select & {5{!in.ctrl.is_auipc}};
  assign alu_b_select = rs2_select & {5{!in.ctrl.alu_src}};
  assign alu_a_value = ({32{alu_a_select[4]}} & rs1_value_q) |
                       ({32{alu_a_select[3]}} & ex_value) |
                       ({32{alu_a_select[2]}} & mem_value) |
                       ({32{alu_a_select[1]}} & wb_value) |
                       ({32{alu_a_select[0]}} & in.rs1_val) |
                       ({32{in.ctrl.is_auipc}} & in.pc);
  assign alu_b_value = ({32{alu_b_select[4]}} & rs2_value_q) |
                       ({32{alu_b_select[3]}} & ex_value) |
                       ({32{alu_b_select[2]}} & mem_value) |
                       ({32{alu_b_select[1]}} & wb_value) |
                       ({32{alu_b_select[0]}} & in.rs2_val) |
                       ({32{in.ctrl.alu_src}} & in.imm);
  assign operands_ready = rs1_ready && rs2_ready;
  assign advance = !flush && !hold_ex && (!in.valid || operands_ready);

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
      rs1_ready_q <= 1'b0;
      rs2_ready_q <= 1'b0;
      rs1_value_q <= 32'b0;
      rs2_value_q <= 32'b0;
    end else begin
      if (advance) begin
        rs1_ready_q <= 1'b0;
        rs2_ready_q <= 1'b0;
      end else if (in.valid) begin
        if (!rs1_ready_q && rs1_ready) begin
          rs1_value_q <= rs1_value;
          rs1_ready_q <= 1'b1;
        end
        if (!rs2_ready_q && rs2_ready) begin
          rs2_value_q <= rs2_value;
          rs2_ready_q <= 1'b1;
        end
      end
      if (!hold_ex) begin
        if (in.valid && operands_ready) begin
          reg_q <= in;
          reg_q.rs1_val <= rs1_value;
          reg_q.rs2_val <= rs2_value;
          reg_q.alu_a_val <= alu_a_value;
          reg_q.alu_b_val <= alu_b_value;
        end else begin
          reg_q <= '0;
        end
      end
    end
  end
  assign out = reg_q;
endmodule
