// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Each admitted PC reads a row containing its last successor PC and word.
// The word can satisfy a stalled fetch. EX resolves all control transfers.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              stall_id,
  input  logic              replay,
  input  logic              imem_ready,
  input  logic              redirect,         // result of registered EX checks
  input  logic [31:0]       resolved_pc,
  input  logic              fence_i,          // valid FENCE.I in EX
  input  logic              train_en,
  input  logic [5:0]        train_index,
  input  logic [1:0]        train_value,
  input  logic              mem_transfer,
  input  logic [31:0]       mem_pc,
  input  logic [31:0]       mem_instr,
  output logic              forecast_used,
  output logic [31:0]       forecast_pc,
  output logic [31:0]       fallthrough_q,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  logic [31:0] held_pc_q, pc, instr;
  logic [1:0] counters [0:63];
  logic [1:0] count;
  logic is_branch, is_jal, is_jalr;

  // One synchronous read and one write per cycle. PC[10:2] can alias:
  // the full word address qualifies instruction reuse, and EX checks a
  // control transfer's destination before admitting the speculative successor.
  typedef struct packed {
    logic        valid;
    logic [17:0] word_addr;
    logic [31:0] instr;
  } successor_t;
  successor_t successors [0:511];
  successor_t ram_response_q, held_response_q, response;
  logic [8:0] predecessor_q, sweep_index_q, write_index;
  logic sweep_q, predecessor_valid_q, lookup_valid_q, request_q;
  logic ram_pc, mem_ram_pc, train_pair;
  logic reset_q, hold_q, held_forecast_q;
  logic fresh, hold_slot, steer, row_is_fallthrough, saved_hit, held_hit_q;

  assign ram_pc = pc[31:20] == 0 && pc[1:0] == 0;
  assign mem_ram_pc = mem_pc[31:20] == 0 && mem_pc[1:0] == 0;
  assign train_pair = mem_transfer && mem_ram_pc && predecessor_valid_q;

  assign write_index = sweep_q ? sweep_index_q : predecessor_q;
  always_ff @(posedge clock) begin
    if (sweep_q || train_pair)
      successors[write_index] <= {!sweep_q, mem_pc[19:2], mem_instr};
    if (mem_transfer)
      predecessor_q <= mem_pc[10:2];
    ram_response_q <= successors[pc[10:2]];
  end

  always_ff @(posedge clock) begin
    if (reset || fence_i) begin
      sweep_q             <= 1'b1;
      sweep_index_q       <= '0;
      predecessor_valid_q <= 1'b0;
    end else begin
      if (sweep_q) begin
        sweep_index_q <= sweep_index_q + 1'b1;
        if (&sweep_index_q) sweep_q <= 1'b0;
      end
      // Bubbles and held MEM entries leave the last transferred PC intact.
      if (mem_transfer)
        predecessor_valid_q <= mem_ram_pc && !sweep_q;
    end
  end

  // Prepare the next slot in parallel with EX. A hold replays the current
  // address and row. A redirect selects the EX/MEM PC and can still use
  // the prior row if its saved word matches that full address.
  always_ff @(posedge clock) begin
    reset_q         <= reset;
    hold_q          <= stall;
    // EX uses this same P+4 for the link and for fall-through recovery.
    if (!stall_id) begin
      fallthrough_q[15:0]  <= pc[15:0] + 16'd4;
      fallthrough_q[31:16] <= pc[31:16] + {15'b0, &pc[15:2]};
    end
    request_q       <= is_jal || is_jalr || (is_branch && (instr[31] ^ count[1]));
    lookup_valid_q  <= ram_pc && !sweep_q && !(train_pair && predecessor_q == pc[10:2]);
    held_pc_q       <= pc;
    held_response_q <= response;
    held_forecast_q <= forecast_used;
    held_hit_q      <= saved_hit;
  end

  assign hold_slot = hold_q || replay;
  assign fresh = !reset_q && !redirect && !hold_slot;
  always_comb begin
    response = fresh ? ram_response_q : held_response_q;
    response.valid = !reset_q && !sweep_q && response.valid && (!fresh || lookup_valid_q);
  end
  assign steer         = request_q && lookup_valid_q && ram_response_q.valid && !sweep_q;
  assign forecast_pc   = {12'b0, response.word_addr, 2'b00};
  // A row containing P+4 needs no correction if the branch falls through.
  assign row_is_fallthrough = {12'b0, ram_response_q.word_addr, 2'b00} == fallthrough_q;
  assign forecast_used = !reset_q && !redirect &&
                         (hold_slot ? held_forecast_q : steer && !row_is_fallthrough);
  assign pc = ({32{!reset_q && redirect}} & resolved_pc) |
              ({32{!reset_q && !redirect && hold_slot}} & held_pc_q) |
              ({32{fresh && steer}} & {12'b0, ram_response_q.word_addr, 2'b00}) |
              ({32{fresh && !steer}} & fallthrough_q);
  assign saved_hit = response.valid &&
                     (redirect ? {12'b0, held_response_q.word_addr, 2'b00} == resolved_pc :
                      hold_slot ? held_hit_q : (request_q || row_is_fallthrough));
  assign instr          = imem_ready ? imem_data : response.instr;

  initial begin
    for (int i = 0; i < 64; i++) counters[i] = 2'b01;
  end
  always_ff @(posedge clock) begin
    if (train_en) counters[train_index] <= train_value;
  end

  assign count       = counters[pc[7:2]];
  assign is_branch   = instr[6:0] == 7'b1100011 && instr[14:13] != 2'b01;
  assign is_jal      = instr[6:0] == 7'b1101111;
  assign is_jalr     = instr[6:0] == 7'h67 && instr[14:12] == 3'b000;

  assign imem_addr = pc;

  always_comb begin
    out.pc              = pc;
    out.instr           = instr;
    out.valid           = imem_ready || saved_hit;
    // Predict with the old count, but train from the newest count if two
    // consecutive branch PCs alias. This bypass only feeds the snapshot.
    out.train_count     = train_en && train_index == pc[7:2] ? train_value : count;
  end

endmodule
