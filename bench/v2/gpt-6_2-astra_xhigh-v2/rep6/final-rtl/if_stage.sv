// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Each accepted PC looks up its last observed successor for the next
// cycle. Live fetches also precompute the successor's direct target.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,
  input  logic              imem_ready,
  input  logic              redirect,         // advancing EX corrects fetch
  input  logic [31:0]       redirect_target,
  input  logic              fence_i,
  input  logic              train_en,
  input  logic [6:0]        train_index,
  input  logic [1:0]        train_counter,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc, predicted_pc_q, correction_pc_q;
  logic        correction_q;
  logic [1:0]  counters [0:127];
  logic [1:0]  counter;
  logic        counter_write_q;
  logic [6:0]  counter_index_q;
  logic [1:0]  counter_data_q;
  logic [31:0] displacement, live_target;
  logic        target_ok, live_branch, live_jal, predicted_taken;

  typedef struct packed {
    logic [17:0] pc_word;
    logic [31:0] instr;
    logic [17:0] target_word;
    logic        jal;
    logic        branch;
  } successor_t;

  // A flat memory word lets Gowin infer block RAM. The registered read
  // port uses the packed type to name the fields.
  (* syn_ramstyle = "block_ram" *) logic [69:0] successors [0:511];
  successor_t  read_record_q, held_record_q, candidate;
  logic [8:0]  index_now, read_index_q, held_index_q, prev_index;
  logic        slot_q, uncorrected_q, accepted_q;
  logic        held_prev_valid_q, prev_valid, read_valid, held_valid_q, candidate_valid, hit;
  logic [17:0] predicted_target_word;

  successor_t  fill_record_q;
  logic [8:0]  fill_index_q;
  logic        fill_eligible_q, write_fill;
  (* syn_ramstyle = "distributed_ram" *) logic [15:0] row_masks [0:31];
  logic [31:0] group_valid;
  logic [15:0] write_mask, read_mask_q;
  logic        forward_mask, read_group_valid_q, read_collision_q;

  initial begin
    for (int i = 0; i < 128; i++) counters[i] = 2'b01;
    counter_write_q = 1'b0;
  end

  // Delay the counter RAM write and bypass that sample to the lookup.
  assign counter = counter_write_q && counter_index_q == pc[8:2]
                 ? counter_data_q : counters[pc[8:2]];
  always_ff @(posedge clock) begin
    counter_write_q <= train_en;
    counter_index_q <= train_index;
    counter_data_q  <= train_counter;
    if (counter_write_q) counters[counter_index_q] <= counter_data_q;
  end

  // Choose the immediate before the adder, in parallel with opcode decode.
  assign displacement = imem_data[2]
      ? {{12{imem_data[31]}}, imem_data[19:12], imem_data[20], imem_data[30:21], 1'b0}
      : {{20{imem_data[31]}}, imem_data[7], imem_data[30:25], imem_data[11:8], 1'b0};
  assign live_target = pc + displacement;
  assign target_ok   = live_target[1:0] == 0 && live_target[31:20] == 0;
  assign live_jal    = target_ok && imem_data[6:0] == 7'b1101111;
  assign live_branch = target_ok && imem_data[6:0] == 7'b1100011 && imem_data[14:13] != 2'b01;

  // Read even on holds and corrections. Qualify the RAM output and the
  // matching PC index one cycle later, after both acceptance terms register.
  assign index_now = pc[10:2];
  always_ff @(posedge clock) begin
    read_record_q <= successors[index_now];
    read_index_q  <= index_now;
    slot_q        <= !stall;
    uncorrected_q <= !redirect && !reset && !fence_i;
  end
  assign accepted_q = slot_q && uncorrected_q;

  // Save the last logical lookup before the free-running port replaces it.
  // A redirect can change the successor PC while retaining its predecessor.
  assign candidate       = accepted_q ? read_record_q : held_record_q;
  assign candidate_valid = accepted_q ? read_valid : held_valid_q;
  assign prev_index      = accepted_q ? read_index_q : held_index_q;
  assign prev_valid      = accepted_q || held_prev_valid_q;
  always_ff @(posedge clock) begin
    if (accepted_q) begin
      held_record_q <= read_record_q;
      held_index_q  <= read_index_q;
    end
    if (reset || fence_i) begin
      held_prev_valid_q <= 1'b0;
      held_valid_q      <= 1'b0;
    end else if (accepted_q) begin
      held_prev_valid_q <= 1'b1;
      held_valid_q      <= read_valid;
    end
  end

  // The write port commits the preceding cycle's live training sample.
  // Invalidation discards both its directory entry and any younger sample.
  always_ff @(posedge clock) begin
    fill_index_q    <= prev_index;
    fill_record_q   <= {pc[19:2], imem_data, live_target[19:2], live_jal, live_branch};
    fill_eligible_q <= prev_valid && imem_ready && pc[31:20] == 0 && pc[1:0] == 0;
  end
  assign write_fill = accepted_q && fill_eligible_q;
  always_ff @(posedge clock) begin
    if (write_fill) successors[fill_index_q] <= fill_record_q;
  end

  // Invalid groups may contain stale masks. Start the first fill with a
  // single row, then accumulate one row per clock in distributed RAM.
  assign write_mask = (16'b1 << fill_index_q[3:0])
                    | (group_valid[fill_index_q[8:4]] ? row_masks[fill_index_q[8:4]] : 16'b0);
  assign forward_mask = write_fill && fill_index_q[8:4] == index_now[8:4];
  always_ff @(posedge clock) begin
    if (write_fill) row_masks[fill_index_q[8:4]] <= write_mask;
    if (reset || fence_i) group_valid <= '0;
    else if (write_fill) group_valid[fill_index_q[8:4]] <= 1'b1;

    read_mask_q        <= forward_mask ? write_mask : row_masks[index_now[8:4]];
    read_group_valid_q <= forward_mask || group_valid[index_now[8:4]];
    read_collision_q   <= write_fill && fill_index_q == index_now;
  end

  // Reject both the physical BRAM collision and a logically simultaneous
  // fill whose new record is still waiting in the write stage.
  assign read_valid = read_group_valid_q && read_mask_q[read_index_q[3:0]]
                   && !read_collision_q && !(fill_eligible_q && fill_index_q == read_index_q);

  // Only acceptance depends on the full address comparison. Decode,
  // source-register interlocking, and direction selection run in parallel.
  assign hit = candidate_valid && {12'b0, candidate.pc_word, 2'b00} == pc;
  assign predicted_taken = imem_ready ? (live_jal || (live_branch && counter[1]))
                                      : (candidate.jal || (candidate.branch && counter[1]));
  assign predicted_target_word = imem_ready ? live_target[19:2] : candidate.target_word;

  // Capture both PC alternatives in parallel. Only the registered EX
  // decision selects the corrected address, including on a fetch hold.
  always_ff @(posedge clock) begin
    correction_q    <= redirect && !reset;
    correction_pc_q <= redirect_target;
    if (reset)       predicted_pc_q <= RESET_PC;
    else if (stall)  predicted_pc_q <= pc;
    else             predicted_pc_q <= predicted_taken ? {12'b0, predicted_target_word, 2'b00}
                                                        : pc + 32'd4;
  end
  assign pc = correction_q ? correction_pc_q : predicted_pc_q;

  assign imem_addr = pc;

  always_comb begin
    out.pc                = pc;
    out.instr             = imem_ready ? imem_data : candidate.instr;
    out.predicted_taken   = predicted_taken;
    out.direction_counter = counter;
    out.valid             = imem_ready || hit;
  end

endmodule
