// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, valid is cleared and ID registers a bubble.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // registered correction from MEM
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,      // conditional branch leaves EX
  input  logic [4:0]        train_index,
  input  logic              train_taken,
  input  logic              imem_ready,
  input  logic              store_valid,
  input  logic [29:0]       store_word_addr,
  output logic              replay_hit,
  output logic              store_fetch_conflict,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] sequential_pc;
  logic [1:0]  direction [0:31];
  logic [31:0] branch_imm;
  logic [31:0] jal_imm;
  logic [31:0] direct_target;
  logic        valid_branch;
  logic        direct_jal;
  logic        predicted_taken;
  logic [31:0] fetch_word;
  logic [31:0] replay_word [0:15];
  logic [25:0] replay_tag [0:15];
  logic [15:0] replay_valid;
  logic [3:0] fetch_index;
  logic [3:0] store_index;
  logic       fetch_accepted;

  assign fetch_index = pc[5:2];
  assign store_index = store_word_addr[3:0];
  assign store_fetch_conflict = store_valid &&
                                store_word_addr == pc[31:2];
  assign replay_hit = replay_valid[fetch_index] &&
                      replay_tag[fetch_index] == pc[31:6] &&
                      !store_fetch_conflict;
  // Keep the tag comparator off the instruction-data path. The validity
  // signal independently controls acceptance of a replayed word.
  assign fetch_word = imem_ready ? imem_data : replay_word[fetch_index];
  // A ready live response is safe to cache even while ID is held. The
  // cache write enable must not depend on stall, which itself can depend
  // on replay_hit and create a long replay-lookup feedback path.
  // A store to this word prevents learning its pre-write bus value.
  assign fetch_accepted = imem_ready && !redirect &&
                          !store_fetch_conflict && !reset;

  always_ff @(posedge clock) begin
    if (reset) begin
      replay_valid <= '0;
    end else begin
      if (store_valid && replay_valid[store_index] &&
          replay_tag[store_index] == store_word_addr[29:4])
        replay_valid[store_index] <= 1'b0;
      if (fetch_accepted) begin
        replay_word[fetch_index] <= imem_data;
        replay_tag[fetch_index] <= pc[31:6];
        replay_valid[fetch_index] <= 1'b1;
      end
    end
  end

  assign branch_imm = {{19{fetch_word[31]}}, fetch_word[31], fetch_word[7],
                       fetch_word[30:25], fetch_word[11:8], 1'b0};
  assign jal_imm = {{11{fetch_word[31]}}, fetch_word[31], fetch_word[19:12],
                    fetch_word[20], fetch_word[30:21], 1'b0};
  assign valid_branch = fetch_word[6:0] == 7'b1100011 &&
                        fetch_word[14:12] != 3'd2 && fetch_word[14:12] != 3'd3;
  assign direct_jal = fetch_word[6:0] == 7'b1101111;
  assign direct_target = pc + (direct_jal ? jal_imm : branch_imm);
  assign sequential_pc = pc + 32'd4;
  assign predicted_taken = (direct_target[1:0] == 2'b00) &&
                           ((valid_branch && direction[pc[6:2]][1]) || direct_jal);

  always_comb begin
    next_pc = predicted_taken ? direct_target : sequential_pc;
  end

  // EX has already registered the qualified feedback. Apply it exactly
  // once here; the table update remains one edge after EX resolution.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 32; i++) direction[i] <= 2'b01;
    end else if (train_valid) begin
      if (train_taken) begin
        if (direction[train_index] != 2'b11)
          direction[train_index] <= direction[train_index] + 2'b01;
      end else if (direction[train_index] != 2'b00) begin
        direction[train_index] <= direction[train_index] - 2'b01;
      end
    end
  end

  // The older MEM correction overrides instruction backpressure. A held
  // wrong-path fetch must never discard the registered redirect target.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall)   pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.pc_sequential = sequential_pc;
    out.pc_direct = direct_target;
    out.instr = fetch_word;
    out.predicted_taken = !(flush || redirect) && predicted_taken;
    out.valid = !(flush || redirect);
  end

endmodule
