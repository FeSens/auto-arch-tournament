// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Operand network: the regfile read (LUT-RAM, write-first bypassed) is
// registered here in fabric flops, and the EX forward selects are
// precomputed here (forward_unit, compared against ID/EX.rd and
// EX/MEM.rd) and registered one-hot, together with the pc/imm/four ALU
// operand legs. EX then only AND-ORs registered selects with registered
// data.
//
// The regfile addresses and the selects use the raw fetch word: when imem
// did not deliver, the entry is a valid=0 NOP bubble whose operands are
// never consumed, so the flush mux stays off the LUT-RAM read path.
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
  // raw io_imemData; only opcode + rs1/rs2 fields are used here
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       fetch_word,
  /* verilator lint_on UNUSEDSIGNAL */
  // EX/MEM destination (becomes MEM/WB while this instruction is in EX)
  input  logic [4:0]        ex_mem_rd,
  input  logic              ex_mem_reg_write,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
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
  logic        dec_is_muldiv;
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
    .is_muldiv  (dec_is_muldiv),
    .is_illegal (dec_is_illegal)
  );

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the fetch word — the same
  // fields feed the hazard unit's load-use compare at top level.
  assign rs1_addr = fetch_word[19:15];
  assign rs2_addr = fetch_word[24:20];

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
    ctrl_decoded.is_muldiv  = dec_is_muldiv;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ID/EX register (declared early: its rd/ctrl feed the select compare).
  // valid/ctrl live in their own flops (reset/flush); reg_q.valid and
  // reg_q.ctrl are unused placeholders replaced in `out`.
  /* verilator lint_off UNDRIVEN */
  /* verilator lint_off UNUSEDSIGNAL */
  id_ex_t reg_q;
  /* verilator lint_on UNUSEDSIGNAL */
  /* verilator lint_on UNDRIVEN */
  ctrl_t  ctrl_q;
  logic   valid_q;

  // ── Forward selects (one cycle early) ─────────────────────────────────
  logic f1_x, f1_w, f1_r;
  logic f2_x, f2_w, f2_r;

  forward_unit u_fwd1 (
    .rs          (fetch_word[19:15]),
    .id_ex_rd    (reg_q.rd),
    .id_ex_w_en  (ctrl_q.reg_write),
    .ex_mem_rd   (ex_mem_rd),
    .ex_mem_w_en (ex_mem_reg_write),
    .sel_x       (f1_x),
    .sel_w       (f1_w),
    .sel_rf      (f1_r)
  );

  forward_unit u_fwd2 (
    .rs          (fetch_word[24:20]),
    .id_ex_rd    (reg_q.rd),
    .id_ex_w_en  (ctrl_q.reg_write),
    .ex_mem_rd   (ex_mem_rd),
    .ex_mem_w_en (ex_mem_reg_write),
    .sel_x       (f2_x),
    .sel_w       (f2_w),
    .sel_rf      (f2_r)
  );

  // ── ALU operand legs from the opcode ──────────────────────────────────
  //   a: pc for AUIPC/JAL/JALR, 0 for LUI, rs1 otherwise
  //   b: 4 for JAL/JALR (link = pc+4 through the ALU adder), imm for
  //      OP-IMM/LOAD/STORE/LUI/AUIPC, rs2 otherwise
  // Only the opcode of legal instructions matters: an illegal / FENCE /
  // EBREAK result is never written.
  logic [6:0] opc;
  logic       op_lui, op_auipc, op_jal, op_jalr;
  logic       a_pc, a_rs, b_four, b_imm, b_rs;

  always_comb begin
    opc      = fetch_word[6:0];
    op_lui   = (opc == 7'b0110111);
    op_auipc = (opc == 7'b0010111);
    op_jal   = (opc == 7'b1101111);
    op_jalr  = (opc == 7'b1100111);
    a_pc     = op_auipc || op_jal || op_jalr;
    a_rs     = !(a_pc || op_lui);
    b_four   = op_jal || op_jalr;
    b_imm    = (opc == 7'b0010011) || (opc == 7'b0000011) ||
               (opc == 7'b0100011) || op_lui || op_auipc;
    b_rs     = !(b_four || b_imm);
  end

  // ── One-hot ALU result selects from the fetch word ────────────────────
  // OP / OP-IMM pick by funct3 (instr[30] = SUB for OP funct3=0, and the
  // arithmetic fill for SRA/SRAI); every other opcode takes the adder
  // (LUI 0+imm, AUIPC, JAL/JALR link, don't-care for the rest). M-ops,
  // illegal and bubble entries never write this result.
  logic       op_op, alu_rr, rr_sub, m_op, op_br;
  logic [2:0] f3;
  logic       r_add, r_sub, r_slt, r_sltu, r_xor, r_or, r_and;
  logic       r_sll, r_shr, r_sra;
  xsel_t      k;          // this instruction's result class (EX/MEM leg)

  always_comb begin
    f3     = fetch_word[14:12];
    op_op  = (opc == 7'b0110011);
    alu_rr = op_op || (opc == 7'b0010011);
    rr_sub = op_op && fetch_word[30];
    r_add  = !alu_rr || (f3 == 3'd0 && !rr_sub);
    r_sub  = alu_rr && f3 == 3'd0 && rr_sub;
    r_sll  = alu_rr && f3 == 3'd1;
    r_slt  = alu_rr && f3 == 3'd2;
    r_sltu = alu_rr && f3 == 3'd3;
    r_xor  = alu_rr && f3 == 3'd4;
    r_shr  = alu_rr && f3 == 3'd5;
    r_sra  = alu_rr && f3 == 3'd5 && fetch_word[30];
    r_or   = alu_rr && f3 == 3'd6;
    r_and  = alu_rr && f3 == 3'd7;
    // M-ops (funct7 = 1; bit 25 is 0 for every legal non-M OP) put the
    // muldiv result on the lg leg. Exactly one class bit is set.
    m_op   = op_op && fetch_word[25];
    k.add  = r_add && !m_op;
    k.sub  = r_sub && !m_op;
    k.sh   = (r_sll || r_shr) && !m_op;
    k.lg   = r_slt || r_sltu || r_xor || r_or || r_and || m_op;
    op_br  = (opc == 7'b1100011);
  end

  // ── Class-qualified x selects ─────────────────────────────────────────
  // sel_x points at the instruction now in ID/EX, which will be in EX/MEM
  // while this one is in EX; its registered class (reg_q.k) picks the
  // EX/MEM leg that holds its value, so each x select stays one-hot.
  logic [3:0]  k_x;       // reg_q.k as a plain vector {add, sub, sh, lg}
  logic [31:0] b_const;
  always_comb begin
    k_x     = reg_q.k;
    b_const = b_four ? 32'd4 : b_imm ? imm : 32'd0;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  // Flush (redirect / load-use bubble) clears only valid and ctrl: the
  // data fields, prediction bits and selects of an invalid, ctrl=0 entry
  // are never consumed (forward/hazard gate on ctrl.reg_write/mem_read,
  // redirect on ctrl.is_branch/is_jump, RVFI on valid). The data fields
  // are enabled by !stall alone, so the flush net only reaches valid/ctrl.
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      ctrl_q  <= '0;
      valid_q <= 1'b0;
    end else if (!stall) begin
      ctrl_q  <= ctrl_decoded;
      valid_q <= in.valid;
    end
  end

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.pred_taken <= in.pred_taken;
      reg_q.pred_ctr   <= in.pred_ctr;
      reg_q.pc       <= in.pc;
      reg_q.rs1_val  <= rs1_data;
      reg_q.rs2_val  <= rs2_data;
      reg_q.imm      <= imm;
      reg_q.rd       <= in.instr[11:7];
      reg_q.rs1_addr <= in.instr[19:15];
      reg_q.rs2_addr <= in.instr[24:20];
      reg_q.instr    <= in.instr;
      reg_q.s1_x     <= {4{f1_x}} & k_x;
      reg_q.s1_w     <= f1_w;
      reg_q.s1_r     <= f1_r;
      reg_q.s2_x     <= {4{f2_x}} & k_x;
      reg_q.s2_w     <= f2_w;
      reg_q.s2_r     <= f2_r;
      reg_q.a_x      <= {4{f1_x && a_rs}} & k_x;
      reg_q.a_w      <= f1_w && a_rs;
      reg_q.a_r      <= f1_r && a_rs;
      reg_q.a_pc     <= a_pc;
      reg_q.b_x      <= {4{f2_x && b_rs}} & k_x;
      reg_q.b_w      <= f2_w && b_rs;
      reg_q.b_r      <= f2_r && b_rs;
      reg_q.b_const  <= b_const;
      // Branch-compare operand copies (own select flops, branch-only so
      // synthesis cannot merge them with the s1/s2/a/b selects).
      reg_q.p1_x     <= {4{f1_x && op_br}} & k_x;
      reg_q.p1_w     <= f1_w && op_br;
      reg_q.p1_r     <= f1_r && op_br;
      reg_q.p2_x     <= {4{f2_x && op_br}} & k_x;
      reg_q.p2_w     <= f2_w && op_br;
      reg_q.p2_r     <= f2_r && op_br;
      // BEQ/BNE -> eq, BLT/BGE -> lt, BLTU/BGEU -> ltu; funct3[0] inverts.
      reg_q.c_eq     <= (f3[2:1] == 2'b00);
      reg_q.c_lt     <= (f3[2:1] == 2'b10);
      reg_q.c_ltu    <= (f3[2:1] == 2'b11);
      reg_q.c_inv    <= f3[0];
      reg_q.k        <= k;
      reg_q.r_add    <= r_add;
      reg_q.r_sub    <= r_sub;
      reg_q.r_slt    <= r_slt;
      reg_q.r_sltu   <= r_sltu;
      reg_q.r_xor    <= r_xor;
      reg_q.r_or     <= r_or;
      reg_q.r_and    <= r_and;
      reg_q.r_sll    <= r_sll;
      reg_q.r_shr    <= r_shr;
      reg_q.r_sra    <= r_sra;
    end
  end

  always_comb begin
    out       = reg_q;
    out.ctrl  = ctrl_q;
    out.valid = valid_q;
  end

endmodule
