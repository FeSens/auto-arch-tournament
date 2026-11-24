// rtl/if_stage.sv
//
// Predict from the active bus word and read the possible next PCs in
// parallel. A ready bus word can bypass an empty queue. Replay uses it
// only for ordered enqueue, and enters decode through the queue head.
// Registered EX recovery replaces the bus request and flushes the queue.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              issue_hold,
  input  logic              recovery_hold,   // older dmem op on a nonbranch correction
  input  logic              load_in_ex,
  input  logic [4:0]        load_rd,
  input  logic              load_word,
  output load_follower_t    follower,
  input  logic              redirect,         // advancing EX correction
  input  logic              fence_i,          // advancing EX FENCE.I
  input  logic              ex_direct_taken,
  input  logic              recover_indirect,
  input  logic [31:0]       ex_sequential_pc,
  input  logic [31:0]       ex_direct_target,
  input  logic [31:0]       mem_indirect_target,
  input  logic [5:0]        mem_indirect_index,
  input  branch_resolution_t branch,
  input  logic [5:0]        train_index,
  input  logic              train_negative,
  output logic              branch_correction,
  output logic              recovery_pending_q,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam int QUEUE_DEPTH = 5;
  localparam logic [QUEUE_DEPTH-1:0] FIRST_SLOT = 5'b00001;
  localparam logic [31:0] LAST_MAPPED_PC = 32'h000f_fffc;

  typedef struct packed {
    logic [29:0] word_pc;
    logic [31:0] instr;
    logic        predicted_taken;
    logic        last_mapped_word;
  } fetch_slot_t;
  localparam int SLOT_WIDTH = 64;

  logic [31:0] predicted_pc_q;
  logic [5:0]  predicted_index_q;
  logic        predicted_in_window_q, predicted_last_word_q;
  logic        redirect_q;
  logic        select_sequential_q, legacy_direct_q, select_indirect_q;
  logic        branch_sequential, branch_direct, select_direct;
  logic [31:0] recovery_sequential_pc_q, recovery_direct_target_q;
  logic [5:0]  recovery_sequential_index_q, recovery_direct_index_q;
  logic [31:0] request_pc;
  logic        recovery_sequential_in_window_q, recovery_direct_in_window_q;
  logic        recovery_sequential_last_word_q, recovery_direct_last_word_q;
  logic        request_in_window, request_last_word;
  logic        parked_q, park;
  logic        stale_request_q, await_corrected_q;
  logic [17:0] held_word_q;

  // Select the registered address and its window flags in parallel.
  // JALR's effective address is already registered in EX/MEM.
  always_ff @(posedge clock) begin
    recovery_sequential_pc_q <= ex_sequential_pc;
    recovery_direct_target_q <= ex_direct_target;
    recovery_sequential_index_q <= ex_sequential_pc[7:2] ^ ex_sequential_pc[13:8];
    recovery_direct_index_q     <= ex_direct_target[7:2] ^ ex_direct_target[13:8];
    recovery_sequential_in_window_q <= ex_sequential_pc[31:20] == 12'b0;
    recovery_direct_in_window_q     <= ex_direct_target[31:20] == 12'b0;
    recovery_sequential_last_word_q <= ex_sequential_pc == LAST_MAPPED_PC;
    recovery_direct_last_word_q     <= ex_direct_target == LAST_MAPPED_PC;
    select_sequential_q <= redirect && !ex_direct_taken && !recover_indirect;
    legacy_direct_q     <= redirect && ex_direct_taken;
    select_indirect_q   <= recover_indirect;

    if (reset) begin
      redirect_q <= 1'b0;
      parked_q   <= 1'b0;
    end else begin
      redirect_q <= redirect;
      parked_q   <= park || (parked_q && !recovery_pending_q);
    end
  end

  assign branch_direct = branch.taken && branch.direct_if_taken;
  assign branch_sequential = branch.taken ? branch.sequential_if_taken
                                          : branch.sequential_if_untaken;
  assign branch_correction = branch_direct || branch_sequential;
  assign recovery_pending_q = redirect_q || branch_correction;
  assign select_direct = legacy_direct_q || branch_direct;

  localparam int NORMAL = 0, SEQUENTIAL = 1, DIRECT = 2, INDIRECT = 3;
  logic [3:0]  select_request, fetch_in_window, fetch_last_word;
  logic [31:0] fetch_pc [0:3];
  logic [5:0]  fetch_index [0:3];
  assign select_request[NORMAL]     = !recovery_pending_q;
  assign select_request[SEQUENTIAL] = select_sequential_q || branch_sequential;
  assign select_request[DIRECT]     = select_direct;
  assign select_request[INDIRECT]   = select_indirect_q;

  assign fetch_pc[NORMAL]     = predicted_pc_q;
  assign fetch_pc[SEQUENTIAL] = recovery_sequential_pc_q;
  assign fetch_pc[DIRECT]     = recovery_direct_target_q;
  assign fetch_pc[INDIRECT]   = mem_indirect_target;
  assign fetch_in_window = {mem_indirect_target[31:20] == 12'b0, recovery_direct_in_window_q,
                            recovery_sequential_in_window_q, predicted_in_window_q};
  assign fetch_last_word = {mem_indirect_target == LAST_MAPPED_PC, recovery_direct_last_word_q,
                            recovery_sequential_last_word_q, predicted_last_word_q};
  assign fetch_index[NORMAL]     = predicted_index_q;
  assign fetch_index[SEQUENTIAL] = recovery_sequential_index_q;
  assign fetch_index[DIRECT]     = recovery_direct_index_q;
  assign fetch_index[INDIRECT]   = mem_indirect_index;

  assign imem_addr = stale_request_q && !recovery_pending_q
                   ? {12'b0, held_word_q, 2'b00} : request_pc;

  logic [17:0] target_word, word_offset;
  logic        is_jal, is_branch, use_j_offset;
  logic        halfword_offset;

  assign is_jal    = imem_data[6:0] == 7'b1101111;
  // Legal branch funct3 values are 000, 001, and 100 through 111.
  assign is_branch = imem_data[6:0] == 7'b1100011 && (imem_data[14] || !imem_data[13]);

  // Opcode bit 3 distinguishes JAL from branches, so offset extraction
  // can start in parallel with the decode that qualifies the target.
  assign use_j_offset   = imem_data[3];
  assign word_offset    = use_j_offset
                        ? {imem_data[19:12], imem_data[20], imem_data[30:22]}
                        : {{8{imem_data[31]}}, imem_data[7], imem_data[30:25], imem_data[11:9]};
  assign halfword_offset = use_j_offset ? imem_data[21] : imem_data[8];

  logic [63:0] counter_valid;
  logic [1:0]  direction_table [0:63];
  logic        fetch_direction_table [0:63];
  logic        train_pending_q;
  logic [5:0]  pending_index_q;
  logic [1:0]  taken_counter_q, untaken_counter_q;
  logic [1:0]  pending_counter_q;
  logic        train_pending_hit;
  logic [1:0]  train_base_counter;
  logic        predict_taken;

  // Read at the index registered for EX. Forward the preceding update
  // while it writes the RAM, including when two branch PCs share an index.
  assign train_pending_q = branch.taken ? branch.train_if_taken : branch.train_if_untaken;
  assign pending_counter_q = branch.taken ? taken_counter_q : untaken_counter_q;
  assign train_pending_hit = train_pending_q && pending_index_q == train_index;
  assign train_base_counter = train_pending_hit ? pending_counter_q
                            : counter_valid[train_index] ? direction_table[train_index]
                                                         : {train_negative, !train_negative};
  always_ff @(posedge clock) begin
    pending_index_q <= train_index;
    taken_counter_q <= {|train_base_counter, train_base_counter[1] || !train_base_counter[0]};
    untaken_counter_q <= {&train_base_counter, train_base_counter == 2'b10};

    if (reset) begin
      counter_valid   <= '0;
    end else if (train_pending_q) counter_valid[pending_index_q] <= 1'b1;

    if (!reset && train_pending_q) begin
      direction_table[pending_index_q]       <= pending_counter_q;
      fetch_direction_table[pending_index_q] <= pending_counter_q[1];
    end
  end

  localparam int RETAIN_BANK = 0, SEQUENTIAL_BANK = 1, DIRECT_BANK = 2, REPLAY_BANK = 3;

  typedef struct packed {
    logic [31:0] instr;
    logic        taken;
    logic [17:0] successor;
    logic [5:0]  successor_index;
    logic        successor_last;
  } replay_payload_t;

  typedef struct packed {
    logic        valid;
    logic [7:0]  tag;
    replay_payload_t payload;
  } replay_record_t;

  replay_payload_t replay_payload;
  replay_record_t ram_write_data;
  localparam int PAYLOAD_WIDTH = $bits(replay_payload);
  localparam int RECORD_WIDTH = $bits(ram_write_data);
  logic [PAYLOAD_WIDTH-1:0] bank_payload [0:3];
  logic [9:0] read_index [0:3];
  logic [3:0] next_bank, read_bank_q, read_collision_q, bank_tag_match;
  logic [1:0] payload_bank_q;
  logic       replay_hit;

  logic [17:0] request_sequential_word, fill_sequential_q, fill_direct_q;
  logic [31:0] fill_instr_q;
  logic [7:0] fill_tag_q;
  logic [9:0] fill_index_q, sweep_index_q, ram_write_index;
  logic       fill_taken_q;
  logic       fill_pending_q, sweeping_q, ram_write_en, accept_bus;

  // Capture the bus word and both candidates before choosing and folding
  // the cached successor. A cacheable word's successor is always mapped.
  assign ram_write_index = sweeping_q ? sweep_index_q : fill_index_q;
  assign ram_write_en = !reset && !fence_i && (sweeping_q || fill_pending_q);
  assign ram_write_data = sweeping_q ? '0 : {
    1'b1, fill_tag_q, fill_instr_q, fill_taken_q,
    (fill_taken_q ? fill_direct_q : fill_sequential_q),
    (fill_taken_q ? (fill_direct_q[5:0] ^ fill_direct_q[11:6])
                  : (fill_sequential_q[5:0] ^ fill_sequential_q[11:6])),
    (fill_taken_q ? (&fill_direct_q) : (&fill_sequential_q))
  };

  always_ff @(posedge clock) begin
    if (reset || fence_i) begin
      sweeping_q <= 1'b1;
      sweep_index_q <= '0;
      fill_pending_q <= 1'b0;
    end else begin
      if (sweeping_q) begin
        sweep_index_q <= sweep_index_q + 10'd1;
        sweeping_q <= !(&sweep_index_q);
      end
      fill_pending_q <= !sweeping_q && accept_bus && request_in_window && !request_last_word;
    end

    fill_instr_q <= imem_data;
    fill_tag_q   <= request_pc[19:12];
    fill_index_q  <= request_pc[11:2];
    fill_taken_q <= predict_taken;
    fill_sequential_q <= request_sequential_word;
    fill_direct_q <= target_word;
  end

  // Only the index goes to RAM. The mask and producer PC cross the
  // read edge together, so the tag checks can run alongside the data mux.
  assign read_index[RETAIN_BANK]     = request_pc[11:2];
  assign read_index[SEQUENTIAL_BANK] = request_sequential_word[9:0];
  assign read_index[DIRECT_BANK]     = target_word[9:0];
  assign read_index[REPLAY_BANK]     = replay_payload.successor[9:0];

  always_ff @(posedge clock) begin
    read_bank_q <= (reset || fence_i || sweeping_q) ? '0 : next_bank;
    payload_bank_q <= {next_bank[DIRECT_BANK] || next_bank[REPLAY_BANK],
                       next_bank[SEQUENTIAL_BANK] || next_bank[REPLAY_BANK]};
  end

  for (genvar bank = 0; bank < 4; bank++) begin : gen_replay_bank
    (* syn_ramstyle = "block_ram" *) logic [RECORD_WIDTH-1:0] replay_ram [0:1023];
    replay_record_t read_record_q;
    always_ff @(posedge clock) begin
      if (ram_write_en) replay_ram[ram_write_index] <= ram_write_data;
      read_record_q <= replay_ram[read_index[bank]];
      read_collision_q[bank] <= ram_write_en && ram_write_index == read_index[bank];
    end
    assign bank_payload[bank] = read_record_q.payload;
    assign bank_tag_match[bank] = read_record_q.valid && read_record_q.tag == predicted_pc_q[19:12];
  end

  assign replay_hit = predicted_in_window_q && !predicted_last_word_q
                   && (|(read_bank_q & bank_tag_match & ~read_collision_q));
  assign replay_payload = bank_payload[payload_bank_q];

  // Explicit vectors keep the slot array portable across SV frontends.
  logic [SLOT_WIDTH-1:0] slots_q [0:QUEUE_DEPTH-1];
  fetch_slot_t produced, buffered_head, normal_head;
  load_follower_t bus_follower, buffered_follower;
  localparam int FOLLOWER_WIDTH = $bits(bus_follower);
  logic [FOLLOWER_WIDTH-1:0] slot_follower [0:QUEUE_DEPTH-1];
  logic [QUEUE_DEPTH-1:0] read_ptr_q, write_ptr_q, occupancy_q;
  logic [QUEUE_DEPTH-1:0] next_read_ptr, next_write_ptr, next_occupancy;
  logic empty, full, normal_bus_valid, normal_accept_bus;
  logic normal_accept_replay, accept_replay, enqueue, pop, corrected_enqueue;
  logic [3:0] candidate_taken, successor_in_window, successor_last_word;
  logic [31:0] successor_pc [0:3];
  logic [5:0]  successor_index [0:3];
  logic [3:0]  successor_bank [0:3];
  logic [17:0] candidate_sequential [0:3];
  logic [17:0] candidate_target [0:3];
  logic [31:0] next_pc;
  logic [5:0]  next_index;
  logic next_in_window, next_last_word;

  assign empty = !occupancy_q[0];
  assign full  = occupancy_q[QUEUE_DEPTH-1];

  assign produced.word_pc          = predicted_pc_q[31:2];
  assign produced.instr            = normal_bus_valid ? imem_data : replay_payload.instr;
  assign produced.predicted_taken  = normal_bus_valid ? candidate_taken[NORMAL] : replay_payload.taken;
  assign produced.last_mapped_word = predicted_last_word_q;

  always_comb begin
    buffered_head = '0;
    buffered_follower = '0;
    for (int slot = 0; slot < QUEUE_DEPTH; slot++) begin
      buffered_head = buffered_head | ({SLOT_WIDTH{read_ptr_q[slot]}} & slots_q[slot]);
      buffered_follower |= {FOLLOWER_WIDTH{read_ptr_q[slot]}} & slot_follower[slot];
    end
  end

  assign normal_head = empty ? {predicted_pc_q[31:2], imem_data,
                                candidate_taken[NORMAL], predicted_last_word_q}
                             : buffered_head;
  assign out.pc               = recovery_pending_q ? request_pc : {normal_head.word_pc, 2'b00};
  assign out.instr            = recovery_pending_q ? imem_data : normal_head.instr;
  assign out.predicted_taken  = recovery_pending_q ? predict_taken : normal_head.predicted_taken;
  assign out.last_mapped_word = recovery_pending_q ? request_last_word : normal_head.last_mapped_word;
  assign out.valid            = recovery_pending_q ? imem_ready : (!empty || normal_bus_valid);

  // Form the normal ring update without the corrected response or its
  // issue qualifiers. Check each slot before the read pointer selects it.
  hazard_unit u_bus_follower (
    .producer_rd   (load_rd),
    .producer_word (load_word),
    .instr         (imem_data),
    .follower      (bus_follower)
  );
  assign follower = load_in_ex ? (empty ? (normal_bus_valid ? bus_follower : '0) : buffered_follower) : '0;
  assign normal_bus_valid = imem_ready && !parked_q && !stale_request_q;
  assign pop = !empty && !issue_hold && !(load_in_ex && buffered_follower.interlock);
  assign normal_accept_bus = normal_bus_valid && !full;
  assign accept_bus = recovery_pending_q ? imem_ready : normal_accept_bus;
  assign normal_accept_replay = replay_hit && !await_corrected_q && !parked_q
                             && !full && (!imem_ready || stale_request_q);
  assign accept_replay = normal_accept_replay && !recovery_pending_q;
  assign enqueue = normal_accept_replay || (normal_accept_bus &&
                   (!empty || issue_hold || (load_in_ex && bus_follower.interlock)));
  // Only a nonbranch boundary correction can have an older memory hold.
  assign corrected_enqueue = redirect_q && imem_ready && recovery_hold;
  assign park = accept_bus && request_last_word;

  for (genvar slot = 0; slot < QUEUE_DEPTH; slot++) begin : gen_slot
    /* verilator lint_off UNUSEDSIGNAL */
    fetch_slot_t payload;
    /* verilator lint_on UNUSEDSIGNAL */
    assign payload = slots_q[slot];
    hazard_unit u_slot_follower (
      .producer_rd   (load_rd),
      .producer_word (load_word),
      .instr         (payload.instr),
      .follower      (slot_follower[slot])
    );

    // The write pointer names an unused slot whenever the queue has
    // space. Only enqueue publishes its data by advancing the pointer.
    always_ff @(posedge clock) begin
      if (slot == 0 && corrected_enqueue)
        slots_q[slot] <= {request_pc[31:2], imem_data, predict_taken, request_last_word};
      else if (!full && write_ptr_q[slot])
        slots_q[slot] <= produced;
    end
  end

  assign next_read_ptr = pop ? {read_ptr_q[QUEUE_DEPTH-2:0], read_ptr_q[QUEUE_DEPTH-1]} : read_ptr_q;
  assign next_write_ptr = enqueue ? {write_ptr_q[QUEUE_DEPTH-2:0], write_ptr_q[QUEUE_DEPTH-1]} : write_ptr_q;
  always_comb begin
    case ({enqueue, pop})
      2'b10:   next_occupancy = {occupancy_q[QUEUE_DEPTH-2:0], 1'b1};
      2'b01:   next_occupancy = {1'b0, occupancy_q[QUEUE_DEPTH-1:1]};
      default: next_occupancy = occupancy_q;
    endcase
  end

  always_ff @(posedge clock) begin
    if (reset || recovery_pending_q) begin
      read_ptr_q  <= FIRST_SLOT;
      write_ptr_q <= !reset && corrected_enqueue ? (FIRST_SLOT << 1) : FIRST_SLOT;
      occupancy_q <= !reset && corrected_enqueue ? FIRST_SLOT : '0;
    end else begin
      read_ptr_q  <= next_read_ptr;
      write_ptr_q <= next_write_ptr;
      occupancy_q <= next_occupancy;
    end
  end

  // Once replay advances past an unready request, discard its response
  // even if a later replay step returns the producer to the same PC.
  always_ff @(posedge clock) begin
    if (reset || recovery_pending_q || imem_ready) stale_request_q <= 1'b0;
    else if (accept_replay) stale_request_q <= 1'b1;

    if (!stale_request_q) held_word_q <= predicted_pc_q[19:2];

    // A corrected request keeps its bus ownership across a stall.
    if (reset) await_corrected_q <= 1'b0;
    else if (recovery_pending_q || accept_bus) await_corrected_q <= !imem_ready;
  end

  // Compute successors from each registered PC before selecting the
  // current request. A stalled corrected request becomes the next PC.
  for (genvar path = 0; path < 4; path++) begin : gen_successor
    logic [29:0] word_pc;
    logic [17:0] sequential_word;
    logic [11:0] next_page, sequential_page;
    logic sequential_last, sequential_carry, target_carry, predict_direct;
    logic fetch_direction, pending_hit, step_bus;

    assign word_pc = fetch_pc[path][31:2];
    assign sequential_word = word_pc[17:0] + 18'd1;
    assign candidate_sequential[path] = sequential_word;
    assign sequential_carry = &word_pc[17:0];
    assign next_page = word_pc[29:18] + 12'd1;
    assign sequential_page = sequential_carry ? next_page : word_pc[29:18];
    assign sequential_last = word_pc == 30'h0003fffe;
    assign step_bus = path == NORMAL ? normal_accept_bus : imem_ready;
    // In page zero the sum remains mapped if its carry cancels the
    // sign of the displacement.
    assign {target_carry, candidate_target[path]} = {1'b0, word_pc[17:0]} + {1'b0, word_offset};
    assign pending_hit = train_pending_q && pending_index_q == fetch_index[path];
    assign fetch_direction = pending_hit ? pending_counter_q[1]
                           : counter_valid[fetch_index[path]] ? fetch_direction_table[fetch_index[path]]
                                                             : imem_data[31];
    assign predict_direct = fetch_in_window[path] && !halfword_offset
                         && target_carry == imem_data[31]
                         && (is_jal || (is_branch && fetch_direction));
    assign candidate_taken[path] = predict_direct && !fetch_last_word[path];

    logic step_direct, step_sequential, replay_step, retain;
    logic [5:0] sequential_index, target_index;
    assign step_direct = step_bus && candidate_taken[path];
    assign replay_step = path == NORMAL && normal_accept_replay;
    assign step_sequential = step_bus && !predict_direct && !fetch_last_word[path];
    assign retain = !(step_bus || replay_step) || fetch_last_word[path];
    assign successor_bank[path] = {replay_step, step_direct, step_sequential, retain};
    assign successor_pc[path] = ({32{step_direct}} & {12'b0, candidate_target[path], 2'b00})
                              | ({32{step_sequential}} & {sequential_page, sequential_word, 2'b00})
                              | ({32{replay_step}} & {12'b0, replay_payload.successor, 2'b00})
                              | ({32{retain}} & fetch_pc[path]);
    assign sequential_index = sequential_word[5:0] ^ sequential_word[11:6];
    assign target_index = candidate_target[path][5:0] ^ candidate_target[path][11:6];
    assign successor_index[path] = ({6{step_direct}} & target_index)
                                 | ({6{step_sequential}} & sequential_index)
                                 | ({6{replay_step}} & replay_payload.successor_index)
                                 | ({6{retain}} & fetch_index[path]);
    assign successor_in_window[path] = fetch_in_window[path]
                                    || (step_bus && sequential_carry && (&word_pc[29:18]));
    assign successor_last_word[path] = fetch_last_word[path] || (step_direct && (&candidate_target[path]))
                                    || (replay_step && replay_payload.successor_last)
                                    || (step_sequential && sequential_last);
  end

  always_comb begin
    request_pc = '0;
    request_in_window = 1'b0;
    request_last_word = 1'b0;
    request_sequential_word = '0;
    target_word = '0;
    predict_taken = 1'b0;
    next_pc = '0;
    next_index = '0;
    next_in_window = 1'b0;
    next_last_word = 1'b0;
    next_bank = '0;
    for (int path = 0; path < 4; path++) begin
      request_pc |= {32{select_request[path]}} & fetch_pc[path];
      request_in_window |= select_request[path] && fetch_in_window[path];
      request_last_word |= select_request[path] && fetch_last_word[path];
      request_sequential_word |= {18{select_request[path]}} & candidate_sequential[path];
      target_word |= {18{select_request[path]}} & candidate_target[path];
      predict_taken |= select_request[path] && candidate_taken[path];
      next_pc |= {32{select_request[path]}} & successor_pc[path];
      next_index |= {6{select_request[path]}} & successor_index[path];
      next_in_window |= select_request[path] && successor_in_window[path];
      next_last_word |= select_request[path] && successor_last_word[path];
      next_bank |= {4{select_request[path]}} & successor_bank[path];
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      predicted_pc_q        <= '0;
      predicted_index_q     <= '0;
      predicted_in_window_q <= 1'b1;
      predicted_last_word_q <= 1'b0;
    end else begin
      predicted_pc_q        <= next_pc;
      predicted_index_q     <= next_index;
      predicted_in_window_q <= next_in_window;
      predicted_last_word_q <= next_last_word;
    end
  end

endmodule
