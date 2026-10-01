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
  input  logic              branch_stall,
  input  logic              pipeline_block,
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  input  logic              id_ex_w_en,
  input  logic [4:0]        id_ex_rd,
  input  logic              ex_mem_w_en,
  input  logic [4:0]        ex_mem_rd,
  input  logic [31:0]       ex_mem_w_data,
  input  logic              mem_wb_w_en,
  input  logic [4:0]        mem_wb_rd,
  input  logic [31:0]       mem_wb_w_data,
  output logic              branch_redirect,
  output logic [31:0]       branch_redirect_target,
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

  // ID-stage operand bypasses are used only for the branch comparison.
  // An EX/MEM load is interlocked by hazard_unit until its value reaches
  // MEM/WB, so the EX/MEM bypass here always contains a usable result.
  logic [31:0] branch_rs1;
  logic [31:0] branch_rs2;
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic        branch_misalign;
  logic [4:0]  dec_rs1_addr;
  logic [4:0]  dec_rs2_addr;
  logic [1:0]  dec_fwd_rs1_sel;
  logic [1:0]  dec_fwd_rs2_sel;
  ctrl_t       ctrl_for_pipe;

  // Select where each source will live in the consumer's EX cycle.  The
  // current ID/EX writer advances to EX/MEM, while the current EX/MEM
  // writer advances to MEM/WB on the same edge that captures this consumer.
  // A load-use interlock delays consumers until a load is in MEM/WB.
  always_comb begin
    dec_rs1_addr = in.instr[19:15];
    dec_rs2_addr = in.instr[24:20];

    if (id_ex_w_en && (id_ex_rd != 5'd0) && (id_ex_rd == dec_rs1_addr))
      dec_fwd_rs1_sel = 2'd1;
    else if (ex_mem_w_en && (ex_mem_rd != 5'd0) && (ex_mem_rd == dec_rs1_addr))
      dec_fwd_rs1_sel = 2'd2;
    else
      dec_fwd_rs1_sel = 2'd0;

    if (id_ex_w_en && (id_ex_rd != 5'd0) && (id_ex_rd == dec_rs2_addr))
      dec_fwd_rs2_sel = 2'd1;
    else if (ex_mem_w_en && (ex_mem_rd != 5'd0) && (ex_mem_rd == dec_rs2_addr))
      dec_fwd_rs2_sel = 2'd2;
    else
      dec_fwd_rs2_sel = 2'd0;
  end

  always_comb begin
    branch_rs1 = rs1_data;
    branch_rs2 = rs2_data;
    if (ex_mem_w_en && (ex_mem_rd != 5'd0) && (ex_mem_rd == dec_rs1_addr))
      branch_rs1 = ex_mem_w_data;
    else if (mem_wb_w_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == dec_rs1_addr))
      branch_rs1 = mem_wb_w_data;

    if (ex_mem_w_en && (ex_mem_rd != 5'd0) && (ex_mem_rd == dec_rs2_addr))
      branch_rs2 = ex_mem_w_data;
    else if (mem_wb_w_en && (mem_wb_rd != 5'd0) && (mem_wb_rd == dec_rs2_addr))
      branch_rs2 = mem_wb_w_data;

    case (dec_branch_op)
      BR_BEQ:  branch_cond = (branch_rs1 == branch_rs2);
      BR_BNE:  branch_cond = (branch_rs1 != branch_rs2);
      BR_BLT:  branch_cond = ($signed(branch_rs1) <  $signed(branch_rs2));
      BR_BGE:  branch_cond = ($signed(branch_rs1) >= $signed(branch_rs2));
      BR_BLTU: branch_cond = (branch_rs1 <  branch_rs2);
      BR_BGEU: branch_cond = (branch_rs1 >= branch_rs2);
      default: branch_cond = 1'b0;
    endcase

    // Fetch payload bits may be arbitrary while valid is low. Keep their
    // decoded operation from redirecting fetch or entering the pipeline.
    branch_taken    = in.valid && dec_is_branch && !dec_is_illegal && branch_cond;
    branch_target   = in.pc + imm;
    branch_misalign = branch_taken && (branch_target[1:0] != 2'b00);
    branch_redirect = branch_taken && !branch_misalign && !branch_stall
                    && !pipeline_block;
    branch_redirect_target = branch_target;

    ctrl_for_pipe = in.valid ? ctrl_decoded : '0;
    if (in.valid && branch_misalign)
      ctrl_for_pipe.is_illegal = 1'b1;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= dec_is_branch ? branch_rs1 : rs1_data;
      reg_q.rs2_val  <= dec_is_branch ? branch_rs2 : rs2_data;
      reg_q.imm      <= imm;
      reg_q.branch_taken   <= branch_taken;
      reg_q.branch_target  <= branch_target;
      reg_q.branch_misalign <= branch_misalign;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.fwd_rs1_sel <= dec_fwd_rs1_sel;
      reg_q.fwd_rs2_sel <= dec_fwd_rs2_sel;
      reg_q.ctrl     <= ctrl_for_pipe;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
