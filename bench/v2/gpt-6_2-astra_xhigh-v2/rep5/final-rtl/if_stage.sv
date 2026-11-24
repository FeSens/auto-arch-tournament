// IF and ID share the instruction bus and register-file read addresses.
// The PC is the fetch register. ID/EX captures the prediction on issue.
module if_stage (
  input  logic        clock,
  input  logic        reset,
  input  logic        stall,
  input  logic        issue,
  input  logic        stall_id,
  input  logic        redirect,
  input  logic [31:2] redirect_target,
  input  logic [31:0] rs1_data,
  input  logic [31:0] rs2_data,
  input  logic        rs1_ready,
  input  logic        rs2_ready,
  input  logic        train,
  input  logic [6:0]  train_index,
  input  logic [1:0]  train_counter,
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_data,
  input  logic        imem_ready,
  output if_id_t      out
);
  logic [31:2] pc_word;
  logic [31:0] pc, pc_plus4, direct_target, direct_offset;
  logic        is_jal, is_branch, eq_branch_ready, branch_direction;
  logic        direct_taken, jalr_taken;

  // P predicts the word for the second issue after P. An exception only
  // steers the RAM read. The word itself carries the full in-window PC.
  typedef struct packed {
    logic        valid;
    logic [19:2] pc;
    logic [31:0] instr;
  } fetch_word_t;
  typedef struct packed {
    logic        valid;
    logic [3:0]  tag;
    logic [9:0]  row;
  } exception_t;
  typedef struct packed {
    logic [12:2] source;
    logic        matched;
  } history_t;

  (* syn_ramstyle = "distributed_ram" *) logic [14:0] exceptions [0:127];
  (* syn_ramstyle = "block_ram" *) logic [50:0] words [0:1023];
  exception_t exception_entry;
  history_t recent, older;
  logic [1:0] history_valid;
  logic [10:0] scrub;
  logic [9:0] sequential_row, read_row, write_row;
  logic matched, nonsequential, in_window, hit;
  logic fill_q, train_exception_q, exception_valid_q;
  logic [12:2] source_q;
  logic [19:2] fill_pc_q;
  logic [31:0] fill_instr_q;
  logic [6:0] exception_write_index;
  fetch_word_t ram_word;
  // Preserve the fabric stage that separates the block RAM from decode.
  (* syn_preserve = 1 *) fetch_word_t candidate;
  logic read_ok_q, candidate_ok_q;
  logic fence_issue, fence_in_ex;
  logic [31:0] instr;

  assign in_window = pc[31:20] == 0;
  assign sequential_row = pc[11:2] + 10'd2;
  assign exception_entry = exceptions[pc[8:2]];
  assign matched = exception_entry.valid && exception_entry.tag == pc[12:9];
  assign read_row = matched ? exception_entry.row : sequential_row;
  assign nonsequential = (older.source[11:2] + 10'd2) != pc[11:2];

  // Sample the transaction on issue and use the RAM write ports one
  // clock later, even if the next instruction stalls.
  always_ff @(posedge clock) begin
    fill_pc_q         <= pc[19:2];
    fill_instr_q      <= imem_data;
    source_q          <= older.source;
    exception_valid_q <= nonsequential;
    train_exception_q <= history_valid[1] && (nonsequential || older.matched);
  end

  assign write_row = scrub[10] ? fill_pc_q[11:2] : scrub[9:0];
  assign exception_write_index = scrub[10] ? source_q[8:2] : scrub[6:0];
  always_ff @(posedge clock) begin
    if (!scrub[10] || fill_q)
      words[write_row] <= {scrub[10], fill_pc_q, fill_instr_q};
    if (!scrub[10] || (fill_q && train_exception_q))
      exceptions[exception_write_index] <= {scrub[10] && exception_valid_q,
                                             source_q[12:9], fill_pc_q[11:2]};
    if (issue)
      ram_word <= words[read_row];
  end

  always_ff @(posedge clock) begin
    if (issue) begin
      candidate <= ram_word;
      recent <= {pc[12:2], matched};
      older <= recent;
    end
  end

  assign hit = candidate_ok_q && candidate.valid && in_window && candidate.pc == pc[19:2];
  assign instr = imem_ready ? imem_data : candidate.instr;
  assign fence_issue = issue && instr[6:0] == 7'b0001111 && instr[14:12] == 3'b001;

  always_ff @(posedge clock) begin
    if (reset || fence_issue) begin
      scrub <= '0;
      history_valid <= '0;
      read_ok_q <= 1'b0;
      candidate_ok_q <= 1'b0;
      fill_q <= 1'b0;
    end else begin
      if (!scrub[10]) scrub <= scrub + 11'd1;
      fill_q <= scrub[10] && issue && imem_ready && in_window;
      // issue excludes a redirect. Keep both stages available for the
      // corrected PC, which must pass the same address check as any other.
      if (issue) begin
        history_valid <= {history_valid[0], 1'b1};
        read_ok_q <= scrub[10] && !(fill_q && read_row == fill_pc_q[11:2]);
        candidate_ok_q <= read_ok_q;
      end
    end
  end

  // An older store in MEM may complete on the edge FENCE.I leaves EX.
  // Wait until the following cycle to accept fresh code from the bus.
  always_ff @(posedge clock) begin
    if (reset)          fence_in_ex <= 1'b0;
    else if (!stall_id) fence_in_ex <= fence_issue;
  end

  // One asynchronous lookup and one shared synchronous write port.
  // The high bit holds at one once all 128 rows have been initialized.
  (* syn_ramstyle = "distributed_ram" *) logic [1:0] counters [0:127];
  logic [7:0] sweep;
  logic [1:0] counter;
  logic [6:0] write_index;

  always_ff @(posedge clock) begin
    if (reset)          sweep <= 8'd0;
    else if (!sweep[7]) sweep <= sweep + 8'd1;
  end
  assign write_index = sweep[7] ? train_index : sweep[6:0];
  always_ff @(posedge clock) begin
    if (!sweep[7] || train)
      counters[write_index] <= sweep[7] ? train_counter : 2'b01;
  end
  assign counter = sweep[7] ? counters[pc[8:2]] : 2'b01;

  assign is_jal = instr[6:0] == 7'b1101111;
  assign is_branch = instr[6:0] == 7'b1100011 && instr[14:13] != 2'b01;
  assign eq_branch_ready = instr[14:13] == 2'b00 && rs1_ready && rs2_ready;
  assign branch_direction = eq_branch_ready ? ((rs1_data == rs2_data) ^ instr[12])
                                            : counter[1];

  // Opcode bit 3 distinguishes J from B for the shared target adder.
  assign direct_offset = instr[3]
      ? {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0}
      : {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
  assign direct_target = pc + direct_offset;
  assign pc_plus4 = pc + 32'd4;
  assign direct_taken = (is_jal || (is_branch && branch_direction)) &&
                        direct_target[31:20] == 0 && direct_target[1:0] == 0;
  // With a ready base and an immediate of zero the predicted JALR target
  // is exact. Bit zero is discarded for both prediction and execution.
  assign jalr_taken = instr[6:0] == 7'b1100111 && instr[14:12] == 0 &&
                      instr[31:20] == 0 && rs1_ready &&
                      rs1_data[31:20] == 0 && !rs1_data[1];

  // Every admitted target is word-aligned. Both taken prediction paths
  // also checked the instruction window, so their upper bits are zero.
  // Capture the direct target in parallel with the register comparison.
  // A taken BEQ/BNE only needs to clock its direction bit on this edge.
  logic [19:2] direct_pc_q;
  logic [31:2] other_pc_q;
  logic direct_q;
  assign pc_word = direct_q ? {12'b0, direct_pc_q} : other_pc_q;
  assign pc = {pc_word, 2'b00};
  always_ff @(posedge clock) begin
    if (reset) begin
      direct_q   <= 1'b0;
      other_pc_q <= '0;
    end else if (redirect) begin
      direct_q   <= 1'b0;
      other_pc_q <= redirect_target;
    end else if (!stall) begin
      direct_q   <= direct_taken;
      other_pc_q <= jalr_taken ? {12'b0, rs1_data[19:2]} : pc_plus4[31:2];
    end
    if (!stall) direct_pc_q <= direct_target[19:2];
  end

  assign imem_addr           = pc;
  assign out.pc              = pc;
  assign out.pc_plus4        = pc_plus4;
  assign out.direct_target   = direct_target;
  assign out.alternate_pc    = direct_taken ? pc_plus4[31:2] : direct_target[31:2];
  assign out.counter         = counter;
  assign out.predicted_taken = direct_taken || jalr_taken;
  assign out.instr           = instr;
  assign out.valid           = (imem_ready || hit) && !fence_in_ex;
endmodule
