// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the raw fetched instruction plus the
// regfile read data. The ID/EX register is owned by this module so the
// decoded view of instruction n is latched by end of cycle n+1.
//
// ID/EX flush is kill-bit-only: flush clears valid and the side-effect
// control bits (reg_write, mem_read, mem_write, is_branch, is_jump and the
// pre-decoded redirect bits br_ok/br_bad/jal_ok/jal_bad/jalr_k); all
// data fields load whenever the stage is not stalled. This keeps EX's
// late redirect off the data flops.
//
// Operands are resolved here, one stage early: the MEM-stage producer
// (EX/MEM occupant, value from mem_stage incl. same-cycle load data) wins
// over the regfile read (write-first for MEM/WB). Only the EX/MEM -> EX
// bypass for the ID/EX occupant is left to EX, via registered selects.
// pc + imm, pc + 4, the LUI/AUIPC/link result, operand B and one-hot
// result-class / branch-op selects are also precomputed and registered.
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
  // EX/MEM occupant (MEM-stage producer)
  input  logic [4:0]        ex_mem_rd,
  input  logic              ex_mem_fwd_ok,
  input  logic [31:0]       mem_fwd_val,
  // EX clears the ID/EX occupant's reg_write (misaligned jump)
  input  logic              ex_wb_kill,
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

  // Regfile read addresses come straight from the raw instruction — these
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

  // ── One-hot result class / branch op / mul signs ────────────────────────
  logic [RS_W-1:0] alu_sel;
  logic            shift_arith;
  logic            a_signed;
  logic            b_signed;
  logic            dec_is_jal;

  always_comb begin
    alu_sel = '0;
    if (dec_is_jump || dec_is_lui || dec_is_auipc) begin
      alu_sel[RS_PRE] = 1'b1;
    end else begin
      case (dec_alu_op)
        ALU_SUB:    alu_sel[RS_SUB]   = 1'b1;
        ALU_AND:    alu_sel[RS_AND]   = 1'b1;
        ALU_OR:     alu_sel[RS_OR]    = 1'b1;
        ALU_XOR:    alu_sel[RS_XOR]   = 1'b1;
        ALU_SLT:    alu_sel[RS_SLT]   = 1'b1;
        ALU_SLTU:   alu_sel[RS_SLTU]  = 1'b1;
        ALU_SLL:    alu_sel[RS_SLL]   = 1'b1;
        ALU_SRL, ALU_SRA:
                    alu_sel[RS_SR]    = 1'b1;
        ALU_MUL:    alu_sel[RS_MULLO] = 1'b1;
        ALU_MULH, ALU_MULHU, ALU_MULHSU:
                    alu_sel[RS_MULHI] = 1'b1;
        ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
                    alu_sel[RS_DIV]   = 1'b1;
        default:    alu_sel[RS_ADD]   = 1'b1;
      endcase
    end
    shift_arith = (dec_alu_op == ALU_SRA);
    a_signed    = (dec_alu_op == ALU_MULH) || (dec_alu_op == ALU_MULHSU);
    b_signed    = (dec_alu_op == ALU_MULH);
    dec_is_jal  = dec_is_jump && !dec_is_jalr;
  end

  // ── PC-relative precompute ──────────────────────────────────────────────
  logic [31:0] pc_imm;
  logic [31:0] pc4;
  logic [31:0] pre_result;
  always_comb begin
    pc_imm     = in.pc + imm;
    pc4        = in.pc + 32'd4;
    pre_result = dec_is_lui   ? imm
               : dec_is_auipc ? pc_imm
                              : pc4;
  end

  // ── BTB prediction check ────────────────────────────────────────────────
  // The fetch after this one went to {12'b0, tgt} iff in.pt. That is
  // right only for a branch / JAL with an aligned target pc + imm, i.e.
  // pred_off == imm[31:2] (flop-sourced subtract from IF).
  logic br_okd;
  logic jal_okd;
  logic tgt_ok;
  logic bad_pt;
  logic replay;
  logic early;
  always_comb begin
    br_okd  = dec_is_branch && !imm[1];
    jal_okd = dec_is_jal    && !imm[1];
    tgt_ok  = (in.pred_off == imm[31:2]);
    bad_pt  = in.pt && !((br_okd || jal_okd) && tgt_ok);
    replay  = bad_pt && (br_okd || dec_is_jalr);
    early   = (jal_okd && !in.pt) || bad_pt;
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  // ── Operand resolution ──────────────────────────────────────────────────
  logic fwd1_ex, fwd2_ex, fwd1_mem, fwd2_mem;
  forward_unit u_fwd (
    .rs1           (in.instr[19:15]),
    .rs2           (in.instr[24:20]),
    .id_ex_rd      (reg_q.rd),
    .id_ex_w_en    (reg_q.ctrl.reg_write),
    .ex_wb_kill    (ex_wb_kill),
    .ex_mem_rd     (ex_mem_rd),
    .ex_mem_fwd_ok (ex_mem_fwd_ok),
    .fwd1_ex       (fwd1_ex),
    .fwd2_ex       (fwd2_ex),
    .fwd1_mem      (fwd1_mem),
    .fwd2_mem      (fwd2_mem)
  );

  logic [31:0] rs1_res;
  logic [31:0] rs2_res;
  logic [31:0] op_b;
  always_comb begin
    rs1_res = fwd1_mem ? mem_fwd_val : rs1_data;
    rs2_res = fwd2_mem ? mem_fwd_val : rs2_data;
    op_b    = dec_alu_src ? imm : rs2_res;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      if (!stall) begin
        reg_q.pc          <= in.pc;
        reg_q.rs1_val     <= rs1_res;
        reg_q.rs2_val     <= rs2_res;
        reg_q.op_b        <= op_b;
        reg_q.imm         <= imm;
        reg_q.pc_imm      <= pc_imm;
        reg_q.pc4         <= pc4;
        reg_q.pre_result  <= pre_result;
        reg_q.alu_sel     <= alu_sel;
        reg_q.shift_arith <= shift_arith;
        reg_q.a_signed    <= a_signed;
        reg_q.b_signed    <= b_signed;
        // Branch compare pre-decode (branch_op = funct3 for BRANCH).
        reg_q.br_use_lt   <= dec_branch_op[2];
        // A predicted-taken branch redirects when NOT taken (to pc4).
        reg_q.br_inv      <= dec_branch_op[0] ^ (in.pt && br_okd);
        reg_q.br_uns      <= dec_branch_op[1];
        reg_q.br_ok       <= br_okd;
        reg_q.br_bad      <= dec_is_branch &&  imm[1];
        reg_q.early       <= early;
        reg_q.jal_bad     <= dec_is_jal    &&  imm[1];
        reg_q.jalr_np     <= dec_is_jalr && !in.pt;
        reg_q.pt          <= in.pt;
        reg_q.hit         <= in.hit;
        reg_q.ctr         <= in.ctr;
        reg_q.replay      <= replay;
        reg_q.jfix        <= jal_okd;
        reg_q.alt_pc      <= in.pt ? pc4 : pc_imm;
        reg_q.rd          <= in.instr[11:7];
        reg_q.rs1_addr    <= in.instr[19:15];
        reg_q.rs2_addr    <= in.instr[24:20];
        reg_q.ctrl           <= ctrl_decoded;
        reg_q.ctrl.reg_write <= dec_reg_write && !replay;
        reg_q.instr       <= in.instr;
        reg_q.fwd1_ex     <= fwd1_ex;
        reg_q.fwd2_ex     <= fwd2_ex;
        reg_q.fwdb_ex     <= fwd2_ex && !dec_alu_src;
        reg_q.valid       <= in.valid;
      end
      // Kill bits only: wrong-path / load-use bubble / imem-stall slot.
      if (flush) begin
        reg_q.valid          <= 1'b0;
        reg_q.ctrl.reg_write <= 1'b0;
        reg_q.ctrl.mem_read  <= 1'b0;
        reg_q.ctrl.mem_write <= 1'b0;
        reg_q.ctrl.is_branch <= 1'b0;
        reg_q.ctrl.is_jump   <= 1'b0;
        reg_q.br_ok          <= 1'b0;
        reg_q.br_bad         <= 1'b0;
        reg_q.early          <= 1'b0;
        reg_q.jal_bad        <= 1'b0;
        reg_q.jalr_np        <= 1'b0;
      end
    end
  end

  assign out = reg_q;

endmodule
