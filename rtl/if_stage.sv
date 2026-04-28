// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or EX redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall after mispredict recovery.
//
// A decode-light static predictor recognizes legal B-type conditional
// branches with a negative immediate and direct JALs, provided the predicted
// target is word-aligned. JALR remains unpredicted and resolves in EX.
// A direct-mapped replay table hides external imem stalls only through a
// registered lookahead candidate for the current PC; the IF decision path
// never reads or compares the table combinationally.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              fetch_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;
  localparam logic [31:0] NOP      = 32'h0000_0013;
  localparam int unsigned REPLAY_INDEX_BITS = 8;
  localparam int unsigned REPLAY_ENTRIES    = 1 << REPLAY_INDEX_BITS;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] pc_plus4;
  logic [31:0] fetch_instr;
  logic [31:0] branch_imm;
  logic [31:0] jal_imm;
  logic [31:0] branch_target;
  logic [31:0] jal_target;
  logic [31:0] predicted_target;
  logic        fetch_kill;
  logic        predict_enable;
  logic        branch_opcode;
  logic        branch_funct_legal;
  logic        branch_predict_taken;
  logic        jal_opcode;
  logic        jal_predict_taken;
  logic        predicted_taken;

  logic                              replay_valid [0:REPLAY_ENTRIES-1];
  logic [31:0]                       replay_tag   [0:REPLAY_ENTRIES-1];
  logic [31:0]                       replay_instr [0:REPLAY_ENTRIES-1];
  logic [REPLAY_INDEX_BITS-1:0]      replay_fill_idx;
  logic [REPLAY_INDEX_BITS-1:0]      replay_lookup_idx;
  logic [31:0]                       replay_lookup_pc;
  logic                              replay_cand_valid_q;
  logic [31:0]                       replay_cand_pc_q;
  logic [31:0]                       replay_cand_instr_q;
  logic                              replay_current_hit;
  logic                              replay_fill_bypass;

  assign replay_fill_idx    = pc[REPLAY_INDEX_BITS+1:2];
  assign replay_lookup_idx  = replay_lookup_pc[REPLAY_INDEX_BITS+1:2];
  assign replay_current_hit = replay_cand_valid_q && (replay_cand_pc_q == pc);
  assign fetch_ready        = imem_ready || replay_current_hit;
  assign fetch_instr        = imem_ready         ? imem_data :
                              replay_current_hit ? replay_cand_instr_q :
                                                   NOP;

  always_comb begin
    pc_plus4           = pc + 32'd4;
    branch_imm         = {{19{fetch_instr[31]}}, fetch_instr[31], fetch_instr[7],
                          fetch_instr[30:25], fetch_instr[11:8], 1'b0};
    jal_imm            = {{11{fetch_instr[31]}}, fetch_instr[31], fetch_instr[19:12],
                          fetch_instr[20], fetch_instr[30:21], 1'b0};
    branch_target      = pc + branch_imm;
    jal_target         = pc + jal_imm;
    fetch_kill         = reset || flush || redirect;
    predict_enable     = !fetch_kill && !stall;
    branch_opcode      = (fetch_instr[6:0] == 7'b1100011);
    branch_funct_legal = (fetch_instr[14:12] != 3'd2) && (fetch_instr[14:12] != 3'd3);
    branch_predict_taken = predict_enable
                       && branch_opcode
                       && branch_funct_legal
                       && fetch_instr[31]
                       && (branch_target[1:0] == 2'b00);
    jal_opcode         = (fetch_instr[6:0] == 7'b1101111);
    jal_predict_taken  = predict_enable
                       && jal_opcode
                       && (jal_target[1:0] == 2'b00);
    predicted_taken    = branch_predict_taken || jal_predict_taken;
    predicted_target   = jal_predict_taken ? jal_target : branch_target;

    next_pc = redirect        ? redirect_target :
              predicted_taken ? predicted_target :
                                pc_plus4;
    replay_lookup_pc = redirect ? redirect_target :
                       !stall   ? next_pc :
                                  pc;
    replay_fill_bypass = imem_ready && (pc == replay_lookup_pc);
  end

  // Redirect must override stall: a BRANCH/JAL/JALR in EX may fire
  // redirect on the same cycle as imem_stall or dmem_stall — without
  // this priority the redirect target would be silently dropped, the
  // PC would hold its old (wrong-path) value, and execution would
  // resume on the wrong path once the bus unstalls. Verified by the
  // VexRiscv-binary CoreMark sweep with --istall enabled.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      replay_cand_valid_q <= 1'b0;
      replay_cand_pc_q    <= RESET_PC;
      replay_cand_instr_q <= NOP;
      for (int i = 0; i < REPLAY_ENTRIES; i++) begin
        replay_valid[i] <= 1'b0;
        replay_tag[i]   <= 32'b0;
        replay_instr[i] <= NOP;
      end
    end else begin
      if (imem_ready) begin
        replay_valid[replay_fill_idx] <= 1'b1;
        replay_tag[replay_fill_idx]   <= pc;
        replay_instr[replay_fill_idx] <= imem_data;
      end

      replay_cand_pc_q <= replay_lookup_pc;
      if (replay_fill_bypass) begin
        replay_cand_valid_q <= 1'b1;
        replay_cand_instr_q <= imem_data;
      end else begin
        replay_cand_valid_q <= replay_valid[replay_lookup_idx]
                            && (replay_tag[replay_lookup_idx] == replay_lookup_pc);
        replay_cand_instr_q <= replay_instr[replay_lookup_idx];
      end
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc               = pc;
    out.instr            = fetch_kill ? NOP : fetch_instr;
    out.predicted_taken  = predicted_taken;
    out.predicted_target = predicted_taken ? predicted_target : pc_plus4;
    out.valid            = !fetch_kill;
  end

endmodule
