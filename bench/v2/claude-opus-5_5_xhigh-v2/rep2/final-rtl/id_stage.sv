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
  input  logic              flush,         // load-use bubble only
  // EX redirect: the word captured this cycle is wrong-path. It is
  // captured normally and killed in EX through ID/EX.squash.
  input  logic              redirect,
  input  if_id_t  in,
  // regfile read interface
  output logic [4:0]        rs1_addr,
  output logic [4:0]        rs2_addr,
  input  logic [31:0]       rs1_data,
  input  logic [31:0]       rs2_data,
  // 2-ahead forward: the instruction in MEM (EX/MEM register) and its
  // final result (mem_stage mem_result, live-qualified by mem_fwd_en).
  input  logic [4:0]        ex_mem_rd,
  input  logic [31:0]       mem_result,
  input  logic              mem_fwd_en,
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

  // ── EX pre-decode (registered in ID/EX) ────────────────────────────────
  alu_sel_t alu_sel;
  alu_dec u_alu_dec (.op(dec_alu_op), .sel(alu_sel));

  logic        dec_is_mul, dec_is_div, dec_late;
  logic [31:0] pc_imm;
  always_comb begin
    dec_is_mul = (dec_alu_op == ALU_MUL)   || (dec_alu_op == ALU_MULH) ||
                 (dec_alu_op == ALU_MULHU) || (dec_alu_op == ALU_MULHSU);
    dec_is_div = (dec_alu_op == ALU_DIV)   || (dec_alu_op == ALU_DIVU) ||
                 (dec_alu_op == ALU_REM)   || (dec_alu_op == ALU_REMU);
    dec_late   = dec_mem_read || dec_is_mul || dec_is_div;
    // A steered B/J already fetched its target: EX's redirect (on a
    // wrong steer only) goes to pc + 4. The select sits before the adder.
    pc_imm     = in.pc + (in.pred ? 32'd4 : imm);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // Operand resolution. ID only captures when the whole pipeline advances
  // (stall is raised by every EX/MEM hold, load-use and div_busy), so
  // relative to the incoming instruction:
  //   3-ahead (in MEM/WB now)  -> regfile write-first bypass (rs?_data)
  //   2-ahead (in EX/MEM now)  -> forwarded here from mem_result
  //   1-ahead (in ID/EX now)   -> registered hit; EX bypasses it from
  //                               EX/MEM.alu_result next cycle, qualified
  //                               with the live EX/MEM reg_write
  // A load in ID/EX never reaches the 1-ahead case (load-use bubble); one
  // cycle later it sits in EX/MEM and is forwarded here, but only on a
  // cycle the bus delivers (a dmem stall raises stall). While the new
  // instruction waits in EX (dmem stall) EX/MEM freezes with it; a DIV*
  // latches its operands in its first EX cycle.
  logic rs1_hit_ex, rs2_hit_ex;
  logic fwd_mem_rs1, fwd_mem_rs2;
  logic a_is_pc, a_is_zero, a_is_const, b_is_const;
  logic [31:0] a_const, b_const;
  logic [31:0] rs1_val_d, rs2_val_d, op_a_d, op_b_d;
  always_comb begin
    rs1_hit_ex  = (reg_q.rd  != 5'b0) && (reg_q.rd  == rs1_addr);
    rs2_hit_ex  = (reg_q.rd  != 5'b0) && (reg_q.rd  == rs2_addr);
    fwd_mem_rs1 = (ex_mem_rd != 5'b0) && (ex_mem_rd == rs1_addr) && mem_fwd_en;
    fwd_mem_rs2 = (ex_mem_rd != 5'b0) && (ex_mem_rd == rs2_addr) && mem_fwd_en;

    // ALU operands: a = pc for AUIPC / JAL / JALR (the link value pc+4 is
    // an ALU ADD with b = 4), 0 for LUI (an ADD of imm), else rs1.
    // b = imm when alu_src, 4 for jumps, else rs2.
    a_is_pc    = dec_is_auipc || dec_is_jump;
    a_is_zero  = dec_is_lui;
    a_is_const = a_is_pc || a_is_zero;
    a_const    = a_is_pc ? in.pc : 32'b0;
    b_is_const = dec_alu_src  || dec_is_jump;
    b_const    = dec_is_jump ? 32'd4 : imm;

    // The late mem_result (dmem -> load align) is selected last in front
    // of each ID/EX flop.
    rs1_val_d = fwd_mem_rs1 ? mem_result : rs1_data;
    rs2_val_d = fwd_mem_rs2 ? mem_result : rs2_data;
    op_a_d    = (fwd_mem_rs1 && !a_is_const) ? mem_result
              : a_is_const                   ? a_const    : rs1_data;
    op_b_d    = (fwd_mem_rs2 && !b_is_const) ? mem_result
              : b_is_const                   ? b_const    : rs2_data;
  end

  // Only the control part (valid, ctrl, rd, late, br_ok, jal_ok, jal_mis,
  // is_div) clears on the load-use bubble / an imem-stalled word; a
  // bubble has no reg_write / mem_* / branch / jump / divide, so the data
  // fields it carries are inert. The EX redirect clears nothing here: the
  // wrong-path word is captured with squash = 1 and killed in EX, which
  // keeps the redirect off every ID/EX clear (it only reaches the PC mux,
  // squash, and late's D input).
  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      if (!stall) begin
        reg_q.pc         <= in.pc;
        reg_q.rs1_val    <= rs1_val_d;
        reg_q.rs2_val    <= rs2_val_d;
        reg_q.op_a       <= op_a_d;
        reg_q.op_b       <= op_b_d;
        reg_q.imm        <= imm;
        reg_q.pc_imm     <= pc_imm;
        reg_q.rs1_addr   <= in.instr[19:15];
        reg_q.rs2_addr   <= in.instr[24:20];
        reg_q.rs1_hit_ex <= rs1_hit_ex;
        reg_q.rs2_hit_ex <= rs2_hit_ex;
        reg_q.op_a_hit   <= rs1_hit_ex && !a_is_const;
        reg_q.op_b_hit   <= rs2_hit_ex && !b_is_const;
        reg_q.squash     <= redirect;
        reg_q.res_late   <= dec_is_mul || dec_is_div;
        reg_q.alu_sel    <= alu_sel;
        // BEQ/BNE: eq; BLT/BGE: lt; BLTU/BGEU: ltu; funct3[0] inverts.
        reg_q.sel_eq     <= !dec_branch_op[2];
        reg_q.sel_lt     <= dec_branch_op[2] && !dec_branch_op[1];
        reg_q.sel_ltu    <= dec_branch_op[2] &&  dec_branch_op[1];
        // A steered branch redirects when NOT taken.
        reg_q.cmp_inv    <= dec_branch_op[0] ^ in.pred;
        reg_q.div_rem    <= dec_alu_op == ALU_REM || dec_alu_op == ALU_REMU;
        reg_q.div_signed <= dec_alu_op == ALU_DIV || dec_alu_op == ALU_REM;
        reg_q.instr      <= in.instr;
      end
      // A killed IF word (imem stall) or the load-use slot becomes a
      // bubble here, so its raw bits never reach EX with live control.
      if (flush || (!stall && !in.valid)) begin
        reg_q.rd      <= 5'b0;
        reg_q.ctrl    <= '0;
        reg_q.late    <= 1'b0;
        reg_q.br_ok   <= 1'b0;
        reg_q.jal_ok  <= 1'b0;
        reg_q.jal_mis <= 1'b0;
        reg_q.pred    <= 1'b0;
        reg_q.is_div  <= 1'b0;
        reg_q.valid   <= 1'b0;
      end else if (!stall) begin
        reg_q.rd      <= in.instr[11:7];
        reg_q.ctrl    <= ctrl_decoded;
        // A squashed LOAD / MUL* / DIV* must not interlock its successor.
        reg_q.late    <= dec_late && !redirect;
        reg_q.br_ok   <= dec_is_branch && !imm[1];
        // A steered JAL is already at its target: no redirect.
        reg_q.jal_ok  <= dec_is_jump && !dec_is_jalr && !imm[1] && !in.pred;
        reg_q.pred    <= in.pred;
        reg_q.jal_mis <= dec_is_jump && !dec_is_jalr &&  imm[1];
        reg_q.is_div  <= dec_is_div;
        reg_q.valid   <= in.valid;
      end
    end
  end

  assign out = reg_q;

endmodule
