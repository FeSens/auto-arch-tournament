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
  // Decode-stage branch bypass network.  ex_in is the instruction being
  // executed this cycle; mem_in is in MEM and can provide a load value
  // directly from dmem through mem_bypass_data; wb is the normal writeback
  // path.  EX has priority over MEM over WB, matching program age.
  /* verilator lint_off UNUSEDSIGNAL */
  input  id_ex_t            ex_in,
  input  logic [31:0]       ex_bypass_data,
  input  logic              ex_bypass_valid,
  input  ex_mem_t           mem_in,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [31:0]       mem_bypass_data,
  input  logic              mem_bypass_valid,
  input  logic              wb_w_en,
  input  logic [4:0]        wb_w_addr,
  input  logic [31:0]       wb_w_data,
  // Asserted for a capturable, legal, aligned ID-resolved control-flow
  // instruction whose actual successor differs from fetch's sequential one.
  output logic              early_redirect,
  output logic [31:0]       early_redirect_target,
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

  // ── Decode-stage conditional branch resolution ─────────────────────────
  // A load in EX has no usable result yet.  It is intentionally not selected
  // here and makes the branch wait; on the following cycle the load is in
  // MEM, where mem_bypass_data is the extended dmem result.  The hazard
  // unit holds IF/ID for that one-cycle interlock.
  logic [31:0] branch_rs1;
  logic [31:0] branch_rs2;
  logic        ex_rs1_match;
  logic        ex_rs2_match;
  logic        branch_operands_ready;
  logic        branch_cond;
  logic        branch_taken;
  logic [31:0] branch_target;
  logic [31:0] branch_next_pc;
  logic        branch_target_misaligned;
  logic        branch_resolved_id;
  logic [31:0] jal_target;
  logic        jal_target_misaligned;
  logic        jal_resolved_id;
  logic        control_resolved_id;
  logic [31:0] control_next_pc;

  always_comb begin
    ex_rs1_match = ex_bypass_valid
                && ex_in.rd != 5'b0 && ex_in.rd == rs1_addr;
    ex_rs2_match = ex_bypass_valid
                && ex_in.rd != 5'b0 && ex_in.rd == rs2_addr;

    branch_rs1 = rs1_data;
    if (wb_w_en && wb_w_addr != 5'b0 && wb_w_addr == rs1_addr)
      branch_rs1 = wb_w_data;
    if (mem_bypass_valid && mem_in.rd != 5'b0
        && mem_in.rd == rs1_addr)
      branch_rs1 = mem_bypass_data;
    if (ex_rs1_match && !ex_in.ctrl.mem_read)
      branch_rs1 = ex_bypass_data;

    branch_rs2 = rs2_data;
    if (wb_w_en && wb_w_addr != 5'b0 && wb_w_addr == rs2_addr)
      branch_rs2 = wb_w_data;
    if (mem_bypass_valid && mem_in.rd != 5'b0
        && mem_in.rd == rs2_addr)
      branch_rs2 = mem_bypass_data;
    if (ex_rs2_match && !ex_in.ctrl.mem_read)
      branch_rs2 = ex_bypass_data;

    // The only unforwardable source is a matching load currently in EX.
    // x0 never creates a dependency because it is not writable.
    branch_operands_ready = !(ex_in.valid && ex_in.ctrl.mem_read
                           && ex_in.rd != 5'b0
                           && (ex_in.rd == rs1_addr || ex_in.rd == rs2_addr));

    case (dec_branch_op)
      BR_BEQ:  branch_cond = (branch_rs1 == branch_rs2);
      BR_BNE:  branch_cond = (branch_rs1 != branch_rs2);
      BR_BLT:  branch_cond = ($signed(branch_rs1) <  $signed(branch_rs2));
      BR_BGE:  branch_cond = ($signed(branch_rs1) >= $signed(branch_rs2));
      BR_BLTU: branch_cond = (branch_rs1 <  branch_rs2);
      BR_BGEU: branch_cond = (branch_rs1 >= branch_rs2);
      default: branch_cond = 1'b0;
    endcase

    branch_taken             = dec_is_branch && branch_cond;
    branch_target            = in.pc + imm;
    branch_next_pc           = branch_taken ? branch_target : (in.pc + 32'd4);
    branch_target_misaligned = branch_taken && (branch_target[1:0] != 2'b00);

    // Do not resolve a target that EX must convert to the architecturally
    // required instruction-address-misaligned trap.  Also do not send a
    // redirect for an instruction that cannot be captured this cycle.
    branch_resolved_id = in.valid && dec_is_branch && !dec_is_illegal
                      && branch_operands_ready && !branch_target_misaligned
                      && !stall && !flush;

    // JAL is operand-independent, so it needs neither branch forwarding nor
    // a load-use exception. It is only resolved here when this exact IF/ID
    // payload will enter ID/EX; a misaligned target remains for EX to turn
    // into the architectural instruction-address-misaligned trap.
    jal_target = in.pc + imm;
    jal_target_misaligned = dec_is_jump && !dec_is_jalr
                         && (jal_target[1:0] != 2'b00);
    jal_resolved_id = in.valid && dec_is_jump && !dec_is_jalr
                   && !dec_is_illegal && !jal_target_misaligned
                   && !stall && !flush;

    control_resolved_id = branch_resolved_id || jal_resolved_id;
    control_next_pc = jal_resolved_id ? jal_target : branch_next_pc;
    early_redirect_target = control_next_pc;
    early_redirect = control_resolved_id
                  && (control_next_pc != in.predicted_next_pc);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      // Capture the same current operands that ID used for the comparison so
      // EX's retained resolution and RVFI rs*_rdata agree with ID.
      reg_q.rs1_val  <= dec_is_branch ? branch_rs1 : rs1_data;
      reg_q.rs2_val  <= dec_is_branch ? branch_rs2 : rs2_data;
      reg_q.imm      <= imm;
      reg_q.predicted_next_pc <= in.predicted_next_pc;
      reg_q.control_resolved_id <= control_resolved_id;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.ctrl     <= ctrl_decoded;
      reg_q.instr    <= in.instr;
      reg_q.valid    <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
