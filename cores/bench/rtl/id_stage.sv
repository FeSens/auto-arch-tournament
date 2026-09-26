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
// The ID/EX register is split in two so the late bubble decision
// (flush = load-use or redirect) drives the sync clear of 8 flops
// instead of the reset/enable pins of the whole ~240-bit register:
//   - control half: valid, pred_taken and ctrl.{reg_write, mem_read,
//     mem_write, is_branch, is_jump, is_div}. Cleared on reset || flush,
//     otherwise captured when !hold.
//   - data half: every other field. No reset, captured when !hold.
// A bubble therefore carries the killed instruction's payload with the
// control bits cleared. That payload is inert: every side effect keys
// off the control bits (redirect and the misalign trap off is_branch /
// is_jump / pred_taken, the BHT write off valid && is_branch, the divide
// start off valid && is_div, forwarding / load-use / regfile write off
// reg_write / mem_read, the dmem enables off mem_read / mem_write, RVFI
// off valid). A valid entry always has its data half captured on the
// same edge as its control half.
//
// Latency:        1 cycle (ID/EX register clocked here).
// RVFI fields:    feeds rs1_addr, rs1_rdata, rs2_addr, rs2_rdata, insn,
//                 trap (via ctrl.is_illegal).
module id_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,    // freeze ID/EX (dmem stall, divide busy)
  input  logic              flush,   // bubble: clear the control half
  input  if_id_t  in,
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
    .is_div     (dec_is_div),
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
    ctrl_decoded.is_div     = dec_is_div;
    ctrl_decoded.mem_read   = dec_mem_read;
    ctrl_decoded.mem_write  = dec_mem_write;
    ctrl_decoded.mem_width  = dec_mem_width;
    ctrl_decoded.mem_sext   = dec_mem_sext;
    ctrl_decoded.reg_write  = dec_reg_write;
    ctrl_decoded.mem_to_reg = dec_mem_to_reg;
    ctrl_decoded.is_illegal = dec_is_illegal;
  end

  // ALU opcode -> one-hot controls, decoded here so EX's ALU runs from
  // ID/EX flops with no opcode decode on its path.
  alu_ctl_t alu_ctl_decoded;
  alu_predecode u_alu_pd (.op(dec_alu_op), .ctl(alu_ctl_decoded));

  // ── ID/EX register ──────────────────────────────────────────────────────
  // Data half: the whole next-state bundle, resetless. Its copies of the
  // 8 control-half fields are overridden in `out` and never read, so
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
    d_next.valid      = in.valid;
  end

  always_ff @(posedge clock) begin
    if (!hold) data_q <= d_next;
  end

  // Control half. Fetch-time prediction travels with the instruction for
  // EX to check; reset/flush clear pred_taken, so a bubble is never
  // predicted.
  logic valid_q;
  logic pred_taken_q;
  logic reg_write_q;
  logic mem_read_q;
  logic mem_write_q;
  logic is_branch_q;
  logic is_jump_q;
  logic is_div_q;

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
    end else if (!hold) begin
      valid_q      <= in.valid;
      pred_taken_q <= in.pred_taken;
      reg_write_q  <= dec_reg_write;
      mem_read_q   <= dec_mem_read;
      mem_write_q  <= dec_mem_write;
      is_branch_q  <= dec_is_branch;
      is_jump_q    <= dec_is_jump;
      is_div_q     <= dec_is_div;
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
  end

endmodule
