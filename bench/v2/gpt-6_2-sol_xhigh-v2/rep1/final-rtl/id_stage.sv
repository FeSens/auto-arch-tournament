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
  input  logic              hold,
  input  logic              fetch_accept,
  input  logic              squash_candidate,
  input  logic              replay_consumer,
  input  logic [1:0]        replay_load_match,
  input  logic [31:0]       replay_rs1,
  input  logic [31:0]       replay_rs2,
  output logic [31:0]       candidate_pc,
  input  logic              candidate_btb_hit,
  input  logic [1:0]        candidate_btb_counter,
  // ID uses the update's write enables, PC and counter.
  /* verilator lint_off UNUSEDSIGNAL */
  input  btb_update_t       btb_update,
  /* verilator lint_on UNUSEDSIGNAL */
  input  if_id_t  in,
  input  logic [4:0]        ex_rd,
  input  logic [4:0]        mem_rd,
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

  // Only branches and JAL use this sum. Opcode bit 2 distinguishes the
  // two immediate layouts without waiting for the main decode.
  logic [31:0] direct_offset, direct_target;
  assign direct_offset = in.instr[2]
                       ? {{12{in.instr[31]}}, in.instr[19:12], in.instr[20],
                          in.instr[30:21], 1'b0}
                       : {{20{in.instr[31]}}, in.instr[7], in.instr[30:25],
                          in.instr[11:8], 1'b0};
  assign direct_target = in.pc + direct_offset;

  // Match against producers that will advance on the same edge as ID.
  assign rs1_addr = in.instr[19:15];
  assign rs2_addr = in.instr[24:20];

  ctrl_t ctrl_decoded;
  always_comb begin
    ctrl_decoded.alu_op     = dec_alu_op;
    ctrl_decoded.alu_src    = dec_alu_src;
    ctrl_decoded.branch_op  = dec_branch_op;
    ctrl_decoded.is_branch  = dec_is_branch;
    ctrl_decoded.branch_equality = dec_is_branch && dec_branch_op[2:1] == 2'b00;
    ctrl_decoded.uses_rs[0] = dec_is_branch || dec_mem_read || dec_mem_write || dec_is_jalr
                           || (!dec_is_illegal && (in.instr[6:0] == 7'b0110011
                                                  || in.instr[6:0] == 7'b0010011));
    ctrl_decoded.uses_rs[1] = dec_is_branch || dec_mem_write
                           || (!dec_is_illegal && in.instr[6:0] == 7'b0110011);
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
  id_ex_t reg_q;
  logic corrected_q;
  logic same_index_update, replace_entry, btb_hit;
  logic [1:0] btb_counter;

  assign candidate_pc = reg_q.pc;
  // The older EX instruction may have trained as this slot was captured.
  // Repair its metadata against the pending entry, including replacements.
  assign same_index_update = btb_update.write_counter && btb_update.pc_word[4:0] == reg_q.pc[6:2];
  assign replace_entry = same_index_update && btb_update.write_target;
  assign btb_hit = replace_entry ? reg_q.pc[31:20] == 12'b0 && reg_q.pc[1:0] == 2'b00
                                 && btb_update.pc_word[17:5] == reg_q.pc[19:7]
                                 : corrected_q ? candidate_btb_hit : reg_q.btb_hit;
  assign btb_counter = same_index_update ? btb_update.counter
                                         : corrected_q ? candidate_btb_counter : reg_q.btb_counter;

  always_ff @(posedge clock) begin
    if (reset)
      reg_q.valid <= 1'b0;
    else if (!hold || squash_candidate)
      reg_q.valid <= fetch_accept;

    if (!hold || fetch_accept) begin
      reg_q.pc            <= in.pc;
      reg_q.pc_plus4      <= in.pc_plus4;
      reg_q.direct_target <= direct_target;
      reg_q.rs1_val       <= rs1_data;
      reg_q.rs2_val       <= rs2_data;
      reg_q.imm           <= imm;
      reg_q.rd            <= in.instr[11:7];
      reg_q.rs1_addr      <= rs1_addr;
      reg_q.rs2_addr      <= rs2_addr;
      reg_q.ex_match      <= {rs2_addr != 5'b0 && rs2_addr == ex_rd,
                              rs1_addr != 5'b0 && rs1_addr == ex_rd};
      reg_q.mem_match     <= {rs2_addr != 5'b0 && rs2_addr == mem_rd,
                              rs1_addr != 5'b0 && rs1_addr == mem_rd};
      reg_q.ctrl          <= ctrl_decoded;
      reg_q.instr         <= in.instr;
      reg_q.btb_hit       <= in.btb_hit;
      reg_q.btb_counter   <= in.btb_counter;
      corrected_q        <= squash_candidate;
    end else begin
      if (replay_consumer) begin
        // MEM/WB advances on this edge. Keep the other forwarded values
        // and move both raw source matches for the load into the WB lane.
        reg_q.rs1_val   <= replay_rs1;
        reg_q.rs2_val   <= replay_rs2;
        reg_q.ex_match  <= '0;
        reg_q.mem_match <= replay_load_match;
      end
      if (same_index_update) begin
        reg_q.btb_hit     <= btb_hit;
        reg_q.btb_counter <= btb_counter;
      end
    end
  end

  always_comb begin
    out = reg_q;
    out.btb_hit = btb_hit;
    out.btb_counter = btb_counter;
  end

endmodule
