// rtl/id_stage.sv
//
// Decode stage. Combinationally drives the regfile read ports and the
// ID/EX register's next-state from the IF/ID combinational bundle plus
// the regfile read data. The ID/EX register is owned by this module so
// the decoded view of instruction n is latched by end of cycle n+1.
//
// IF's fetch-time prediction (pred_taken, bht_ctr, alt_target) is
// latched into ID/EX unchanged; EX verifies it.
//
// Late branch (late_br from hazard_unit: a BRANCH reading the rd of the
// LOAD in EX): captured with late = 1 and is_branch = pred_taken = 0, so
// EX never redirects, traps or writes the BHT off its stale compare. The
// real prediction stays in the data half (late_pred, bht_ctr) for MEM to
// resolve it.
//
// The ID/EX register is split in two so the late bubble decision
// (flush = load-use or redirect) drives the sync clear of 10 flops
// instead of the reset/enable pins of the whole ~240-bit register:
//   - control half: valid, pred_taken, ld_nz, late and ctrl.{reg_write,
//     mem_read, mem_write, is_branch, is_jump, is_div}. Cleared on
//     reset || flush, otherwise captured when !hold.
//   - data half: every other field. No reset, captured when !hold.
// A bubble therefore carries the killed instruction's payload with the
// control bits cleared. That payload is inert: every side effect keys
// off the control bits (redirect and the misalign trap off is_branch /
// is_jump / pred_taken, the BHT write off valid && is_branch, the divide
// start off valid && is_div, forwarding / load-use / regfile write off
// reg_write / mem_read / ld_nz, the dmem enables off mem_read /
// mem_write, the late-branch unit off late, RVFI off valid). A valid
// entry always has its data half captured on the same edge as its
// control half.
//
// ctrl.is_illegal is only pre-checked here (opcode not in RV32IM): MEM
// ORs in the decoder's full is_illegal from EX/MEM.instr (see
// mem_stage.sv), so the full decode (funct fields plus the 32-bit EBREAK
// match) stays off the imem -> ID/EX path. The pre-check is a subset of
// the full decode, so the retired trap bit is unchanged.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn.
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,    // freeze ID/EX (dmem stall, divide busy)
  input  logic              flush,   // bubble: clear the control half
  // in.pd_br / in.pd_jalr are for the hazard unit only.
  /* verilator lint_off UNUSEDSIGNAL */
  input  if_id_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // hazard_unit: capture the BRANCH as a late branch
  input  logic              late_br,
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
  logic        dec_is_div;
  logic        dec_mem_read;
  logic        dec_mem_write;
  logic [1:0]  dec_mem_width;
  logic        dec_mem_sext;
  logic        dec_reg_write;
  logic        dec_mem_to_reg;

  // is_illegal is left open: MEM decodes it from EX/MEM.instr.
  /* verilator lint_off PINCONNECTEMPTY */
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
    .is_div     (dec_is_div),
    .mem_read   (dec_mem_read),
    .mem_write  (dec_mem_write),
    .mem_width  (dec_mem_width),
    .mem_sext   (dec_mem_sext),
    .reg_write  (dec_reg_write),
    .mem_to_reg (dec_mem_to_reg),
    .is_illegal ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic [31:0] imm;
  imm_gen u_imm (.instr(in.instr), .imm(imm));

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  // Opcode-only illegal pre-check (a subset of the decoder's is_illegal,
  // default illegal). MEM ORs in the full decode.
  logic opc_illegal;
  always_comb begin
    case (in.instr[6:0])
      7'b0110011, 7'b0010011, 7'b0000011, 7'b0100011, 7'b1100011,
      7'b1101111, 7'b1100111, 7'b0110111, 7'b0010111, 7'b0001111,
      7'b1110011: opc_illegal = 1'b0;
      default:    opc_illegal = 1'b1;
    endcase
  end

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
    ctrl_decoded.is_div     = dec_is_div;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_illegal = opc_illegal;
  end

  // One-hot ALU controls, decoded here so EX's ALU runs from ID/EX flops
  // with no opcode decode on its path. They are decoded straight from the
  // instruction bits rather than through dec_alu_op + alu_predecode,
  // which puts a binary re-encode on the imem -> ID/EX path. Legal
  // instructions get exactly alu_predecode(dec_alu_op). Of funct7 only
  // instr[25] (M-ext) and instr[30] (SUB/SRA) are read, so an illegal
  // OP / OP-IMM encoding may select some ALU op, but it never writes rd
  // or touches memory, so its ALU result is unused:
  //   rr  : OP with instr[25] = 0 (base R-type)     ri : OP-IMM
  //   mul : OP with instr[25] = 1 (MUL..REMU; DIV/REM select nothing)
  //   everything else that is not LUI adds (loads, stores, AUIPC; the
  //   ALU result of branches / jumps / FENCE / EBREAK is unused).
  // sub / sra / mul_*_sgn are only read under their selects.
  logic     opc_op;
  logic     opc_opimm;
  logic     opc_lui;
  logic     alu_rr_ri;
  logic     alu_mul;
  logic [2:0] f3;
  alu_ctl_t alu_ctl_decoded;

  always_comb begin
    f3        = in.instr[14:12];
    opc_op    = (in.instr[6:0] == 7'b0110011);
    opc_opimm = (in.instr[6:0] == 7'b0010011);
    opc_lui   = (in.instr[6:0] == 7'b0110111);
    alu_rr_ri = (opc_op && !in.instr[25]) || opc_opimm;
    alu_mul   = opc_op && in.instr[25];

    alu_ctl_decoded.sub        = alu_rr_ri && ((f3 == 3'd0) ? opc_op && in.instr[30]
                                                             : (f3[2:1] == 2'b01));
    alu_ctl_decoded.sra        = in.instr[30];
    alu_ctl_decoded.mul_a_sgn  = (f3 == 3'd1) || (f3 == 3'd2);   // MULH, MULHSU
    alu_ctl_decoded.mul_b_sgn  = (f3 == 3'd1);                   // MULH
    alu_ctl_decoded.sel_sum    = (alu_rr_ri && f3 == 3'd0)
                               || !(opc_op || opc_opimm || opc_lui);
    alu_ctl_decoded.sel_and    = alu_rr_ri && f3 == 3'd7;
    alu_ctl_decoded.sel_or     = alu_rr_ri && f3 == 3'd6;
    alu_ctl_decoded.sel_xor    = alu_rr_ri && f3 == 3'd4;
    alu_ctl_decoded.sel_slt    = alu_rr_ri && f3 == 3'd2;
    alu_ctl_decoded.sel_sltu   = alu_rr_ri && f3 == 3'd3;
    alu_ctl_decoded.sel_sll    = alu_rr_ri && f3 == 3'd1;
    alu_ctl_decoded.sel_sr     = alu_rr_ri && f3 == 3'd5;
    alu_ctl_decoded.sel_b      = opc_lui;
    alu_ctl_decoded.sel_mul_lo = alu_mul && f3 == 3'd0;
    alu_ctl_decoded.sel_mul_hi = alu_mul && !f3[2] && (f3 != 3'd0);
  end

  // ── ID/EX register ──────────────────────────────────────────────────────
  // Data half: the whole next-state bundle, resetless. Its copies of the
  // 10 control-half fields are overridden in `out` and never read, so
  // synthesis drops those flops.
  id_ex_t d_next;
  id_ex_t data_q;

  always_comb begin
    d_next.pc         = in.pc;
    d_next.rs1_val    = rs1_data;
    d_next.rs2_val    = rs2_data;
    d_next.imm        = imm;
    d_next.rd         = in.instr[11:7];
    d_next.rs1_addr   = in.instr[19:15];
    d_next.rs2_addr   = in.instr[24:20];
    d_next.ctrl       = ctrl_decoded;
    d_next.alu_ctl    = alu_ctl_decoded;
    d_next.instr      = in.instr;
    d_next.pred_taken = in.pred_taken;
    d_next.bht_ctr    = in.bht_ctr;
    d_next.alt_target = in.alt_target;
    d_next.ld_nz      = 1'b0;
    d_next.late       = 1'b0;
    d_next.late_pred  = in.pred_taken;
    d_next.valid      = in.valid;
  end

  always_ff @(posedge clock) begin
    if (!hold) data_q <= d_next;
  end

  // Control half. Fetch-time prediction travels with the instruction for
  // EX to check; reset/flush clear pred_taken, so a bubble is never
  // predicted. A late branch is captured as inert for EX (is_branch and
  // pred_taken 0). ld_nz = LOAD with rd != x0, registered here so the
  // hazard unit's load-use gate needs no rd != 0 reduction.
  logic valid_q;
  logic pred_taken_q;
  logic reg_write_q;
  logic mem_read_q;
  logic mem_write_q;
  logic is_branch_q;
  logic is_jump_q;
  logic is_div_q;
  logic ld_nz_q;
  logic late_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid_q      <= 1'b0;
      pred_taken_q <= 1'b0;
      reg_write_q  <= 1'b0;
      mem_read_q   <= 1'b0;
      mem_write_q  <= 1'b0;
      is_branch_q  <= 1'b0;
      is_jump_q    <= 1'b0;
      is_div_q     <= 1'b0;
      ld_nz_q      <= 1'b0;
      late_q       <= 1'b0;
    end else if (!hold) begin
      valid_q      <= in.valid;
      pred_taken_q <= in.pred_taken && !late_br;
      reg_write_q  <= dec_reg_write;
      mem_read_q   <= dec_mem_read;
      mem_write_q  <= dec_mem_write;
      is_branch_q  <= dec_is_branch && !late_br;
      is_jump_q    <= dec_is_jump;
      is_div_q     <= dec_is_div;
      ld_nz_q      <= dec_mem_read && (in.instr[11:7] != 5'b0);
      late_q       <= late_br;
    end
  end

  always_comb begin
    out                = data_q;
    out.valid          = valid_q;
    out.pred_taken     = pred_taken_q;
    out.ctrl.reg_write = reg_write_q;
    out.ctrl.mem_read  = mem_read_q;
    out.ctrl.mem_write = mem_write_q;
    out.ctrl.is_branch = is_branch_q;
    out.ctrl.is_jump   = is_jump_q;
    out.ctrl.is_div    = is_div_q;
    out.ld_nz          = ld_nz_q;
    out.late           = late_q;
  end

endmodule
