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
  input  logic [4:0]        ex_rd,
  input  logic              ex_load,
  input  logic              ex_load_word,
  input  logic              ex_write_eligible,
  input  result_sel_t       ex_result_sel,
  input  logic [4:0]        mem_rd,
  input  logic              mem_may_write,
  input  logic              mem_write_eligible,
  output logic              load_use,
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
  logic [31:0] instr;

  assign instr = in.synthetic ? 32'b0 : in.instr;

  decoder u_decoder (
    .instr      (instr),
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
  imm_gen u_imm (.instr(instr), .imm(imm));

  // Regfile read addresses come straight from the IF/ID instruction — these
  // are also wired to the hazard unit at top level for load-use detection.
  assign rs1_addr = instr[19:15];
  assign rs2_addr = instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
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

  branch_sel_t branch_sel;
  assign branch_sel.eq = dec_is_branch && dec_branch_op == BR_BEQ;
  assign branch_sel.ne = dec_is_branch && dec_branch_op == BR_BNE;
  assign branch_sel.lt = dec_is_branch && (dec_branch_op == BR_BLT || dec_branch_op == BR_BLTU);
  assign branch_sel.ge = dec_is_branch && (dec_branch_op == BR_BGE || dec_branch_op == BR_BGEU);
  assign branch_sel.signed_compare = !dec_branch_op[1];

  result_sel_t result_sel;
  always_comb begin
    result_sel = '0;
    if (dec_reg_write && !dec_mem_read) begin
      if (dec_is_jump || dec_is_auipc) begin
        result_sel.other = 1'b1;
      end else begin
        case (dec_alu_op)
          ALU_ADD:                      result_sel.add      = 1'b1;
          ALU_SUB:                      result_sel.sub      = 1'b1;
          ALU_MUL:                      result_sel.mul_low  = 1'b1;
          ALU_MULH, ALU_MULHSU, ALU_MULHU: result_sel.mul_high = 1'b1;
          default:                      result_sel.other    = 1'b1;
        endcase
      end
    end
  end

  // These producers reach EX/MEM and MEM/WB on the consumer's ID/EX edge.
  // A trapping producer leaves the next older value eligible.
  logic [1:0] ex_hit, mem_hit;
  operand_sel_t rs1_sel, rs2_sel;
  logic [31:0] rs1_default, rs2_default;

  assign ex_hit = {rs2_addr == ex_rd, rs1_addr == ex_rd}
                & {2{ex_write_eligible && ex_rd != 5'd0}};
  assign mem_hit = {rs2_addr == mem_rd, rs1_addr == mem_rd}
                 & {2{mem_write_eligible && mem_rd != 5'd0}};
  assign rs1_sel.ex_mem = ex_hit[0] ? ex_result_sel : '0;
  assign rs1_sel.mem_wb = mem_hit[0] && !ex_hit[0];
  assign rs2_sel.ex_mem = ex_hit[1] ? ex_result_sel : '0;
  assign rs2_sel.mem_wb = mem_hit[1] && !ex_hit[1];

  // Zero the register default when a bypass supplies the operand in EX.
  assign rs1_default = (ex_hit[0] || mem_hit[0]) ? '0 : rs1_data;
  assign rs2_default = (ex_hit[1] || mem_hit[1]) ? '0 : rs2_data;

  logic [1:0] response_match, older_match;
  logic load_pair, branch_pair, independent_ready;

  // Use the issue word's raw tags on the interlock path. A load only
  // consumes rs1 for its address, but both raw tags are kept for RVFI.
  assign response_match = {in.instr[24:20] == ex_rd, in.instr[19:15] == ex_rd}
                        & {2{ex_load && ex_rd != 5'd0}};
  assign older_match = {in.instr[24:20] == mem_rd, in.instr[19:15] == mem_rd}
                     & {2{mem_may_write && mem_rd != 5'd0}};
  assign independent_ready = !(|(older_match & ~response_match));
  assign load_pair = in.pair_decode.short_load && ex_load_word && response_match[0];
  assign branch_pair = in.pair_decode.equality_branch && (|response_match) && independent_ready;
  assign load_use = in.valid && !in.synthetic && (|response_match) && !load_pair && !branch_pair;

  // ── ID/EX register ──────────────────────────────────────────────────────
  id_ex_t reg_q;

  always_ff @(posedge clock) begin
    if (!stall) begin
      reg_q.rs1_sel       <= rs1_sel;
      reg_q.rs2_sel       <= rs2_sel;
      reg_q.alu_b_sel     <= dec_alu_src ? '0 : rs2_sel;
      reg_q.alu_b_default <= dec_alu_src ? imm : rs2_default;
      reg_q.rs1_default   <= rs1_default;
      reg_q.rs2_default   <= rs2_default;
      reg_q.result_sel   <= result_sel;
      reg_q.branch_sel   <= branch_sel;
      reg_q.load_pair    <= load_pair;
      reg_q.branch_pair  <= branch_pair;
      reg_q.response_match <= response_match;
      reg_q.pc           <= in.pc;
      reg_q.predicted_taken <= in.predicted_taken;
      reg_q.direct_target_differs <= (dec_is_branch || (dec_is_jump && !dec_is_jalr))
                                  && imm != 32'd4;
      reg_q.divide       <= instr[6:0] == 7'h33 && instr[31:25] == 7'h01 && instr[14];
      reg_q.imm          <= imm;
      // A signed 12-bit immediate plus four fits in 13 bits, including
      // the four positive values that exceed the signed 12-bit range.
      reg_q.jalr_imm_plus_four <= {instr[31], instr[31:20]} + 13'd4;
      reg_q.rd           <= instr[11:7];
      reg_q.rs1_addr     <= rs1_addr;
      reg_q.rs2_addr     <= rs2_addr;
      reg_q.ctrl         <= ctrl_decoded;
      reg_q.instr        <= instr;
    end

    if (reset || flush) reg_q.valid <= 1'b0;
    else if (!stall)    reg_q.valid <= in.valid;
  end

  assign out = reg_q;

endmodule
