// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Refresh held operands before their writers leave the WB stage.
  input  logic              wb_w_en,
  input  logic [4:0]        wb_w_addr,
  input  logic [31:0]       wb_w_data,
  // Lookahead choices for the fetched payload and actual MEM advance.
  input  logic [1:0]        next_rs1_sel,
  input  logic [1:0]        next_rs2_sel,
  input  logic              mem_advance,
  input  logic              mem_w_en,
  input  logic [4:0]        mem_rd,
  output logic [1:0]        fwd_rs1_sel,
  output logic [1:0]        fwd_rs2_sel,
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  logic [4:0]  dec_alu_op;
  logic        dec_alu_src;
  logic [2:0]  dec_branch_op;
  logic        dec_is_branch;
  logic        dec_is_jump;
  logic        dec_is_jalr;
  logic        dec_is_lui;
  logic        dec_is_auipc;
  logic        dec_mem_read;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;
  logic        dec_is_illegal;

  decoder u_decoder (
    .instr      (in.instr),
    .alu_op     (dec_alu_op),
    .alu_src    (dec_alu_src),
    .branch_op  (dec_branch_op),
    .is_branch  (dec_is_branch),
    .is_jump    (dec_is_jump),
    .is_jalr    (dec_is_jalr),
    .is_lui     (dec_is_lui),
    .is_auipc   (dec_is_auipc),
    .mem_read   (dec_mem_read),
    .mem_write  (dec_mem_write),
    .mem_width  (dec_mem_width),
    .mem_sext   (dec_mem_sext),
    .reg_write  (dec_reg_write),
    .mem_to_reg (dec_mem_to_reg),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Static recovery work precedes the existing ID/EX edge. Each branch
  // predicate selects the operand comparison that contradicts the accepted
  // prediction. Alignment suppresses recovery, not the architectural trap.
  logic [31:0] direct_target, sequential_pc;
  logic recover_eq, recover_ne, recover_lt, recover_ge;
  logic recover_ltu, recover_geu, recover_jal, recover_jalr;
  assign direct_target = in.pc + imm;
  assign sequential_pc = in.pc + 32'd4;
  always_comb begin
    recover_eq = 1'b0;
    recover_ne = 1'b0;
    recover_lt = 1'b0;
    recover_ge = 1'b0;
    recover_ltu = 1'b0;
    recover_geu = 1'b0;
    if (dec_is_branch && !dec_is_illegal && direct_target[1:0] == 2'b00) begin
      case (dec_branch_op)
        BR_BEQ: begin
          recover_eq = !in.predicted_taken;
          recover_ne = in.predicted_taken;
        end
        BR_BNE: begin
          recover_ne = !in.predicted_taken;
          recover_eq = in.predicted_taken;
        end
        BR_BLT: begin
          recover_lt = !in.predicted_taken;
          recover_ge = in.predicted_taken;
        end
        BR_BGE: begin
          recover_ge = !in.predicted_taken;
          recover_lt = in.predicted_taken;
        end
        BR_BLTU: begin
          recover_ltu = !in.predicted_taken;
          recover_geu = in.predicted_taken;
        end
        BR_BGEU: begin
          recover_geu = !in.predicted_taken;
          recover_ltu = in.predicted_taken;
        end
        default: ;
      endcase
    end
    recover_jal = dec_is_jump && !dec_is_jalr && !dec_is_illegal
                  && direct_target[1:0] == 2'b00 && !in.predicted_taken;
    recover_jalr = dec_is_jalr && !dec_is_illegal;
  end

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.is_jump    = dec_is_jump;
    ctrl_decoded.is_jalr    = dec_is_jalr;
    ctrl_decoded.is_lui     = dec_is_lui;
    ctrl_decoded.is_auipc   = dec_is_auipc;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  // Operand storage is a real RF-to-EX timing boundary. Keep it separate
  // from ordinary payload state so synthesis cannot absorb the flops.
  typedef struct packed {
    logic [31:0] direct_target, sequential_pc;
    logic recover_eq, recover_ne, recover_lt, recover_ge;
    logic recover_ltu, recover_geu, recover_jal, recover_jalr;
    logic [31:0] pc;
    logic [31:0] imm;
    logic [4:0] rd, rs1_addr, rs2_addr;
    ctrl_t ctrl;
    logic [31:0] instr;
    logic predicted_taken, valid;
  } id_payload_t;
  id_payload_t reg_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [31:0] rs1_val_q, rs2_val_q;
  logic [1:0] rs1_sel_q, rs2_sel_q;
  logic refresh_rs1, refresh_rs2, mem_match_rs1, mem_match_rs2;
  assign refresh_rs1 = wb_w_en && wb_w_addr != 5'b0 && wb_w_addr == reg_q.rs1_addr;
  assign refresh_rs2 = wb_w_en && wb_w_addr != 5'b0 && wb_w_addr == reg_q.rs2_addr;
  assign mem_match_rs1 = mem_w_en && mem_rd != 5'b0 && mem_rd == reg_q.rs1_addr;
  assign mem_match_rs2 = mem_w_en && mem_rd != 5'b0 && mem_rd == reg_q.rs2_addr;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
      rs1_val_q <= 32'b0;
      rs2_val_q <= 32'b0;
      rs1_sel_q <= 2'b0;
      rs2_sel_q <= 2'b0;
    end else begin
      // Recovery never gates payload capture or held WB operand refresh.
      // A load-use bubble retains its payload; a recovery bubble may
      // capture arbitrary raw younger fields, with valid cleared below.
      if (!stall) begin
        reg_q.direct_target <= direct_target;
        reg_q.sequential_pc <= sequential_pc;
        reg_q.recover_eq <= recover_eq;
        reg_q.recover_ne <= recover_ne;
        reg_q.recover_lt <= recover_lt;
        reg_q.recover_ge <= recover_ge;
        reg_q.recover_ltu <= recover_ltu;
        reg_q.recover_geu <= recover_geu;
        reg_q.recover_jal <= recover_jal;
        reg_q.recover_jalr <= recover_jalr;
        reg_q.pc       <= in.pc;
        rs1_val_q      <= rs1_data;
        rs2_val_q      <= rs2_data;
        rs1_sel_q      <= next_rs1_sel;
        rs2_sel_q      <= next_rs2_sel;
        reg_q.imm      <= imm;
        reg_q.rd       <= in.instr[11:7];
        reg_q.rs1_addr <= in.instr[19:15];
        reg_q.rs2_addr <= in.instr[24:20];
        reg_q.ctrl     <= ctrl_decoded;
        reg_q.instr    <= in.instr;
        reg_q.predicted_taken <= in.predicted_taken;
      end else begin
        if (refresh_rs1) rs1_val_q <= wb_w_data;
        if (refresh_rs2) rs2_val_q <= wb_w_data;
        if (mem_advance) begin
          // MEM leaves for WB on this edge. Any older WB value was
          // refreshed above; only the matching advancing MEM is fresher.
          rs1_sel_q <= mem_match_rs1 ? 2'd2 : 2'd0;
          rs2_sel_q <= mem_match_rs2 ? 2'd2 : 2'd0;
        end else begin
          // A data stall holds EX/MEM while WB drains. Preserve that
          // younger producer even if older WB also refreshes the flop.
          if (rs1_sel_q != 2'd1 && refresh_rs1) rs1_sel_q <= 2'd0;
          if (rs2_sel_q != 2'd1 && refresh_rs2) rs2_sel_q <= 2'd0;
        end
      end

      if (flush) reg_q.valid <= 1'b0;
      else if (!stall) reg_q.valid <= in.valid;
    end
  end

  always_comb begin
    out.direct_target = reg_q.direct_target;
    out.sequential_pc = reg_q.sequential_pc;
    out.recover_eq = reg_q.recover_eq;
    out.recover_ne = reg_q.recover_ne;
    out.recover_lt = reg_q.recover_lt;
    out.recover_ge = reg_q.recover_ge;
    out.recover_ltu = reg_q.recover_ltu;
    out.recover_geu = reg_q.recover_geu;
    out.recover_jal = reg_q.recover_jal;
    out.recover_jalr = reg_q.recover_jalr;
    out.pc = reg_q.pc;
    out.rs1_val = rs1_val_q;
    out.rs2_val = rs2_val_q;
    out.imm = reg_q.imm;
    out.rd = reg_q.rd;
    out.rs1_addr = reg_q.rs1_addr;
    out.rs2_addr = reg_q.rs2_addr;
    out.ctrl = reg_q.ctrl;
    out.instr = reg_q.instr;
    out.predicted_taken = reg_q.predicted_taken;
    out.valid = reg_q.valid;
  end
  assign fwd_rs1_sel = rs1_sel_q;
  assign fwd_rs2_sel = rs2_sel_q;

endmodule
