// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// Operand forwarding happens here, at the end of ID: ID/EX op1/op2 hold the
// final ALU / compare operands (forward AND-OR, AUIPC pc and ALU immediate
// folded in) and rv1/rv2 the pure forwarded register values (RVFI only).
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              flush,
  // The FD head of the fetch queue (flops): pc / instr / valid / pred_taken.
  // Every ID/EX field except valid and pred_taken is decoded from in.instr
  // unmasked: a bubble (redirect / empty FD / load-use) is flushed to
  // ctrl = 0, valid = 0 by `flush`, so its data fields are dead and
  // `redirect` stays off the decoder / imm_gen / regfile-address cone.
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // Operand forward sources for the instruction being captured, youngest
  // producer first (see fwd_select.sv):
  input  logic [31:0]       ex_val,       // EX result right now (non-late producer)
  input  logic [31:0]       mem_ld_val,   // MEM-stage load_data (dmem read + align)
  input  logic [31:0]       mem_alu_val,  // EX/MEM.alu_result | mul_q
  input  logic [31:0]       wb_val,       // WB-stage write data
  input  logic [4:0]        mem_rd,       // instruction in MEM (EX/MEM)
  input  logic              mem_we,       // ... reg_write after trap clearing
  input  logic              mem_is_load,
  input  logic [4:0]        wb_rd,        // instruction in WB (MEM/WB)
  input  logic              wb_we,        // ... and it writes the regfile
  // ID/EX register output
  output id_ex_t  out
);

  // ── Combinational decode ────────────────────────────────────────────────
  logic [31:0] raw_instr;
  logic [4:0]  raw_rs1;
  logic [4:0]  raw_rs2;
  assign raw_instr = in.instr;
  assign raw_rs1   = in.instr[19:15];
  assign raw_rs2   = in.instr[24:20];

  logic [4:0]  dec_alu_op;
  logic        dec_is_mul;
  logic        dec_is_div;
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
    .instr      (raw_instr),
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

  always_comb begin
    dec_is_mul = (dec_alu_op == ALU_MUL)  || (dec_alu_op == ALU_MULH)
              || (dec_alu_op == ALU_MULHU) || (dec_alu_op == ALU_MULHSU);
    dec_is_div = (dec_alu_op == ALU_DIV)  || (dec_alu_op == ALU_DIVU)
              || (dec_alu_op == ALU_REM)  || (dec_alu_op == ALU_REMU);
  end

  logic [31:0] imm;
  imm_gen u_imm (.instr(raw_instr), .imm(imm));

  // Regfile read addresses come straight from the raw fetched word — these
  // are also wired to the hazard unit at top level for load-use detection.
  // ID/EX rs1_addr/rs2_addr below still use the masked instruction.
  assign rs1_addr = raw_rs1;
  assign rs2_addr = raw_rs2;

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
    // Results that are not ready at the end of EX: the DSP product (MUL*),
    // the jump link / trap-qualified reg_write (JAL/JALR) and loads. The
    // immediate consumer waits a cycle (hazard_unit) and takes the value
    // from the MEM-now term instead.
    ctrl_decoded.late_res   = dec_mem_read || dec_is_jump || dec_is_mul;
    // Predecoded control flops (parallel to the decoder, loaded into ID/EX
    // with the rest of ctrl): EX / the forward network never re-decode alu_op.
    ctrl_decoded.ex_fwd     = dec_reg_write && !ctrl_decoded.late_res
                           && (raw_instr[11:7] != 5'b0);
    ctrl_decoded.is_div     = dec_is_div;
    ctrl_decoded.mul_sa     = (dec_alu_op == ALU_MULH) || (dec_alu_op == ALU_MULHSU);
    ctrl_decoded.mul_sb     = (dec_alu_op == ALU_MULH);
    ctrl_decoded.sel_mul_lo = (dec_alu_op == ALU_MUL);
    ctrl_decoded.sel_mul_hi = (dec_alu_op == ALU_MULH)  || (dec_alu_op == ALU_MULHU)
                           || (dec_alu_op == ALU_MULHSU);
    // JAL/JALR decode to ALU_ADD but take pc+4: no ALU class for them.
    ctrl_decoded.sel_add    = (dec_alu_op == ALU_ADD) && !dec_is_jump;
    ctrl_decoded.sel_sub    = (dec_alu_op == ALU_SUB);
    ctrl_decoded.sel_and    = (dec_alu_op == ALU_AND);
    ctrl_decoded.sel_or     = (dec_alu_op == ALU_OR);
    ctrl_decoded.sel_xor    = (dec_alu_op == ALU_XOR);
    ctrl_decoded.sel_slt    = (dec_alu_op == ALU_SLT);
    ctrl_decoded.sel_sltu   = (dec_alu_op == ALU_SLTU);
    ctrl_decoded.sel_sll    = (dec_alu_op == ALU_SLL);
    ctrl_decoded.sel_srl    = (dec_alu_op == ALU_SRL);
    ctrl_decoded.sel_sra    = (dec_alu_op == ALU_SRA);
    ctrl_decoded.sel_lui    = (dec_alu_op == ALU_LUI);
    ctrl_decoded.mem_mis    = 1'b0;   // decided in EX
  end

  // ── Operand forwarding (end of ID) ─────────────────────────────────────
  // The ID/EX operand registers hold the FINAL ALU / compare operands, so EX
  // reads them straight from flops. Each operand is a one-hot AND-OR of the
  // producers in flight (youngest first: EX now, MEM now, WB now, regfile).
  // The late EX-now term sits last: one LUT between early_masked and the D
  // pin. ID/EX only loads when the pipeline advances (!stall), and the
  // sources are re-evaluated every cycle the consumer waits in ID, so the
  // captured value is always the freshest one.
  id_ex_t reg_q;

  // A producer in EX forwards only when its result is final at the end of EX
  // and it writes a real register: ctrl.ex_fwd (flop) = reg_write &&
  // !late_res && rd != 0 (late producers stall the consumer instead).
  logic s1_ex, s1_mld, s1_mal, s1_wb, s1_ram;
  logic s2_ex, s2_mld, s2_mal, s2_wb, s2_ram;

  fwd_select u_fwd1 (
    .a(raw_rs1), .ex_rd(reg_q.rd), .ex_we(reg_q.ctrl.ex_fwd),
    .mem_rd(mem_rd), .mem_we(mem_we), .mem_is_load(mem_is_load),
    .wb_rd(wb_rd), .wb_we(wb_we),
    .sel_ex(s1_ex), .sel_mem_ld(s1_mld), .sel_mem_alu(s1_mal),
    .sel_wb(s1_wb), .sel_ram(s1_ram)
  );
  fwd_select u_fwd2 (
    .a(raw_rs2), .ex_rd(reg_q.rd), .ex_we(reg_q.ctrl.ex_fwd),
    .mem_rd(mem_rd), .mem_we(mem_we), .mem_is_load(mem_is_load),
    .wb_rd(wb_rd), .wb_we(wb_we),
    .sel_ex(s2_ex), .sel_mem_ld(s2_mld), .sel_mem_alu(s2_mal),
    .sel_wb(s2_wb), .sel_ram(s2_ram)
  );

  // use_pc / use_imm are decoded straight from the opcode bits of the FD
  // flops (not from the full decoder): for every legal opcode they equal the
  // decoder's is_auipc / (alu_src && !mem_write); an illegal word never
  // writes a register, so its operands are dead.
  //   use_pc  : AUIPC (0010111) -> operand a is the pc
  //   use_imm : OP-IMM, LOAD, AUIPC, LUI, JALR (not STORE: it keeps rs2 as
  //             store data; its address / branch targets use the dedicated
  //             rs1+imm / pc+imm adders reading in.imm). JAL's operand is dead.
  logic        use_pc;
  logic        use_imm;
  logic [31:0] rest1;      // regfile / MEM / WB forward terms (no EX, no const)
  logic [31:0] rest2;
  logic [31:0] base1;      // network without the EX-now term, const folded in
  logic [31:0] base2;
  logic [31:0] op1_d;
  logic [31:0] op2_d;
  logic [31:0] rv1_d;      // pure forwarded register values (RVFI only)
  logic [31:0] rv2_d;

  always_comb begin
    use_pc  = !raw_instr[6] && !raw_instr[5] && raw_instr[4] && raw_instr[2];
    use_imm = !raw_instr[3] && (!raw_instr[5]
                                || (raw_instr[2] && (raw_instr[4] ^ raw_instr[6])));

    // Pure register value (RVFI rs?_rdata): EX-now over MEM / WB / regfile.
    rest1 = ({32{s1_mld}} & mem_ld_val)
          | ({32{s1_mal}} & mem_alu_val)
          | ({32{s1_wb }} & wb_val)
          | ({32{s1_ram}} & rs1_data);
    rest2 = ({32{s2_mld}} & mem_ld_val)
          | ({32{s2_mal}} & mem_alu_val)
          | ({32{s2_wb }} & wb_val)
          | ({32{s2_ram}} & rs2_data);
    rv1_d = s1_ex ? ex_val : rest1;
    rv2_d = s2_ex ? ex_val : rest2;

    // ALU operands: the constant (pc / imm) is folded into the early one-hot
    // selects of the non-EX terms, so the EX term is a plain 2:1 mux on
    // E = m_ex && !use_const with no priority mask on any other select.
    base1 = ({32{s1_mld && !use_pc}} & mem_ld_val)
          | ({32{s1_mal && !use_pc}} & mem_alu_val)
          | ({32{s1_wb  && !use_pc}} & wb_val)
          | ({32{s1_ram && !use_pc}} & rs1_data)
          | ({32{use_pc}}            & in.pc);
    base2 = ({32{s2_mld && !use_imm}} & mem_ld_val)
          | ({32{s2_mal && !use_imm}} & mem_alu_val)
          | ({32{s2_wb  && !use_imm}} & wb_val)
          | ({32{s2_ram && !use_imm}} & rs2_data)
          | ({32{use_imm}}            & imm);
    op1_d = (s1_ex && !use_pc ) ? ex_val : base1;
    op2_d = (s2_ex && !use_imm) ? ex_val : base2;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────

  // Only the valid/ctrl bits (and pred_taken) are flushed: a bubble with
  // valid = 0 and zeroed ctrl cannot write the regfile, access dmem,
  // redirect or raise a load-use hazard, and RVFI only looks at the data
  // fields when valid = 1. The data fields therefore load on !stall and are
  // cleared by `reset` alone, which keeps the late redirect/flush net off
  // ~170 data flops.
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      reg_q.ctrl       <= '0;
      reg_q.valid      <= 1'b0;
      reg_q.pred_taken <= 1'b0;
    end else if (!stall) begin
      reg_q.ctrl       <= ctrl_decoded;
      reg_q.valid      <= in.valid;
      reg_q.pred_taken <= in.pred_taken;
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q.pc       <= '0;
      reg_q.op1      <= '0;
      reg_q.op2      <= '0;
      reg_q.rv1      <= '0;
      reg_q.rv2      <= '0;
      reg_q.imm      <= '0;
      reg_q.rd       <= '0;
      reg_q.rs1_addr <= '0;
      reg_q.rs2_addr <= '0;
      reg_q.instr    <= '0;
    end else if (!stall) begin
      reg_q.pc       <= in.pc;
      reg_q.op1      <= op1_d;
      reg_q.op2      <= op2_d;
      reg_q.rv1      <= rv1_d;
      reg_q.rv2      <= rv2_d;
      reg_q.imm      <= imm;
      reg_q.rd       <= raw_instr[11:7];
      reg_q.rs1_addr <= raw_instr[19:15];
      reg_q.rs2_addr <= raw_instr[24:20];
      reg_q.instr    <= raw_instr;
    end
  end

  assign out = reg_q;

endmodule
