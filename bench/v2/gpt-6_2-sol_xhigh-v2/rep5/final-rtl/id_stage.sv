// rtl/id_stage.sv
//
// Issue stage. Read the selected instruction's encoded register tags
// and capture operand selections and data with its decoded payload.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,
  input  logic              issue_candidate,
  input  logic              issue,
  input  issue_packet_t     in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  input  operand_sel_t      rs1_sel,
  input  operand_sel_t      rs2_sel,
  input  logic              pending_rs1,
  input  logic              pending_rs2,
  // ID/EX register output
  output id_ex_t  out
);

  // The same tags feed the register file, forwarding and late-result checks.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset)
      reg_q.valid <= 1'b0;
    else if (!hold)
      reg_q.valid <= issue;

    // Hold the selectors and their data together while EX is stalled.
    if (issue_candidate) begin
      reg_q.pc               <= in.pc;
      reg_q.direct_target    <= in.direct_target;
      reg_q.predicted_taken  <= in.predicted_taken;
      reg_q.prediction_index <= in.prediction_index;
      reg_q.holds_fetch      <= in.holds_fetch;
      reg_q.rs1_val          <= rs1_data;
      reg_q.rs2_val          <= rs2_data;
      reg_q.rs1_sel          <= rs1_sel;
      reg_q.rs2_sel          <= rs2_sel;
      reg_q.pending_rs1      <= in.late_eligible && pending_rs1;
      reg_q.pending_rs2      <= in.late_eligible && pending_rs2;
      reg_q.late_add         <= in.late_eligible && !in.ctrl.is_branch &&
                                (pending_rs1 || (pending_rs2 && !in.ctrl.alu_src));
      reg_q.late_branch      <= in.late_eligible && in.ctrl.is_branch &&
                                (pending_rs1 || pending_rs2);
      reg_q.alu_select       <= (in.ctrl.is_auipc || in.ctrl.is_jump) ? '0
                                                                     : decode_alu(in.ctrl.alu_op);
      reg_q.imm              <= in.imm;
      reg_q.rd               <= in.instr[11:7];
      reg_q.rs1_addr         <= rs1_addr;
      reg_q.rs2_addr         <= rs2_addr;
      reg_q.ctrl             <= in.ctrl;
      reg_q.instr            <= in.instr;
    end
  end

  assign out = reg_q;

endmodule
