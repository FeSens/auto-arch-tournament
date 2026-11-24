// rtl/if_stage.sv
//
// Fetch, predict and decode into a four-entry flow-through issue FIFO.
// An empty FIFO lets a ready response issue on the acceptance edge.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              issue_stall,
  input  logic              imem_ready,
  input  logic              ex_redirect,
  input  logic [31:2]       ex_redirect_word,
  input  logic              mem_redirect,
  input  logic [31:2]       mem_redirect_word,
  output logic              ex_recovery,
  output logic              mem_recovery,
  input  logic              advance_aperture,
  input  logic              train_branch,
  input  logic [5:0]        train_index,
  input  logic              train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output logic              issue_candidate,
  output logic              issue,
  output issue_packet_t     out
);

  logic [31:2] pc_word, sequential_q, retry_q, ex_target_q, mem_target_q;
  logic [19:2] prediction_q;
  logic sequential_select_q, predicted_select_q, retry_select_q, recovering;
  logic [1:0]  history_q;
  logic [1:0]  counters [0:63];

  logic        update_valid_q, update_taken_q;
  logic [5:0]  update_index_q;
  logic [1:0]  update_counter;

  assign update_counter = counters[update_index_q];

  always_ff @(posedge clock) begin
    if (reset) begin
      history_q      <= 2'b00;
      update_valid_q <= 1'b0;
      update_taken_q <= 1'b0;
      update_index_q <= 6'b0;
      for (int i = 0; i < 64; i++)
        counters[i] <= 2'b01;
    end else begin
      update_valid_q <= train_branch;
      if (train_branch) begin
        history_q      <= {history_q[0], train_taken};
        update_index_q <= train_index;
        update_taken_q <= train_taken;
      end

      // Read the counter when applying the queued outcome so back-to-back
      // updates to the same entry see the result of the first update.
      if (update_valid_q) begin
        if (update_taken_q && update_counter != 2'b11)
          counters[update_index_q] <= update_counter + 2'd1;
        else if (!update_taken_q && update_counter != 2'b00)
          counters[update_index_q] <= update_counter - 2'd1;
      end
    end
  end

  logic        is_branch, is_jal;
  logic        direct_bit1, predicted_taken;
  logic [31:2] direct_word;
  logic [20:2] offset_word;
  logic [18:0] direct_low_sum;
  logic [11:0] pc_upper;
  logic        direct_in_range, target_carry, target_borrow;
  logic [5:0]  prediction_index;
  logic        counter_taken;

  assign is_branch = imem_data[6:0] == 7'b1100011
                  && imem_data[14:13] != 2'b01; // funct3 010 and 011 are reserved
  assign is_jal    = imem_data[6:0] == 7'b1101111;

  // B and J immediates share bits [10:5]. The PC is word aligned,
  // so immediate bit 1 goes straight to EX for the alignment check.
  assign offset_word = {is_jal ? {imem_data[31], imem_data[19:12], imem_data[20]}
                               : {{9{imem_data[31]}}, imem_data[7]},
                        imem_data[30:25],
                        is_jal ? imem_data[24:22] : imem_data[11:9]};
  assign pc_upper = pc_word[31:20];
  assign direct_low_sum = {1'b0, pc_word[19:2]} + {1'b0, offset_word[19:2]};
  assign direct_word[19:2] = direct_low_sum[17:0];
  // The low word carry cancels a negative offset's upper contribution.
  assign target_carry = direct_low_sum[18] && !offset_word[20];
  assign target_borrow = !direct_low_sum[18] && offset_word[20];
  assign direct_word[20] = pc_upper[0] ^ direct_low_sum[18] ^ offset_word[20];
  for (genvar i = 1; i < 12; i++) begin : gen_target_hi
    assign direct_word[i+20] = pc_upper[i] ^ ((target_carry && (&pc_upper[i-1:0])) ||
                                             (target_borrow && !(|pc_upper[i-1:0])));
  end
  assign direct_in_range = direct_low_sum[18]
                         ? (offset_word[20] ? pc_upper == 12'd0 : &pc_upper)
                         : (offset_word[20] ? pc_upper == 12'd1 : pc_upper == 12'd0);
  assign direct_bit1 = is_jal ? imem_data[21] : imem_data[8];

  assign prediction_index = pc_word[7:2] ^ {4'b0, history_q};
  assign counter_taken    = counters[prediction_index][1];
  assign predicted_taken  = imem_ready && !direct_bit1 && direct_in_range
                         && (is_jal || (is_branch && counter_taken));

  // A sequential prediction at the last word accepts one response, then
  // waits for EX to resolve that packet's successor. The tag distinguishes
  // it from any earlier taken instance of that PC in a predicted loop.
  localparam logic [31:2] LAST_IMEM_WORD = 30'h0003ffff;
  logic aperture_wait_q, hold_last_word, resume_fetch;
  logic response_valid, accept_response, advance_request;

  assign hold_last_word = pc_word == LAST_IMEM_WORD && !predicted_taken;
  assign resume_fetch = !recovering && aperture_wait_q && advance_aperture;
  assign advance_request = resume_fetch || (accept_response && !hold_last_word);

  // Select among the registered candidates. MEM's branch is older when
  // both stages request recovery on the same edge.
  assign recovering = mem_recovery || ex_recovery;
  assign pc_word = ({30{mem_recovery}} & mem_target_q)
                 | ({30{ex_recovery && !mem_recovery}} & ex_target_q)
                 | ({30{sequential_select_q && !recovering}} & sequential_q)
                 | ({30{predicted_select_q && !recovering}} & {12'b0, prediction_q})
                 | ({30{retry_select_q && !recovering}} & retry_q);

  always_ff @(posedge clock) begin
    ex_recovery <= !reset && ex_redirect;
    mem_recovery <= !reset && mem_redirect;
    ex_target_q <= ex_redirect_word;
    mem_target_q <= mem_redirect_word;

    sequential_q <= pc_word + 30'd1;
    prediction_q <= direct_word[19:2];
    retry_q <= reset ? '0 : pc_word;
    sequential_select_q <= !reset && advance_request && (resume_fetch || !predicted_taken);
    predicted_select_q <= !reset && advance_request && !resume_fetch && predicted_taken;
    retry_select_q <= reset || !advance_request;

    if (reset)                                  aperture_wait_q <= 1'b0;
    else if (accept_response && hold_last_word)  aperture_wait_q <= 1'b1;
    else if (recovering || resume_fetch)         aperture_wait_q <= 1'b0;
  end

  issue_packet_t response;

  assign imem_addr                 = {pc_word, 2'b00};
  assign response.pc               = imem_addr;
  assign response.instr            = imem_data;
  assign response.direct_target    = {direct_word, direct_bit1, 1'b0};
  assign response.predicted_taken  = predicted_taken;
  assign response.prediction_index = prediction_index;
  assign response.holds_fetch      = hold_last_word;
  assign response.late_eligible   = pc_word != LAST_IMEM_WORD &&
    ((is_branch && imem_data[14:13] == 2'b00) ||
     (imem_data[14:12] == 3'b000 &&
      (imem_data[6:0] == 7'b0010011 ||
       (imem_data[6:0] == 7'b0110011 && imem_data[31:25] == 7'b0))));

  decoder u_decoder (
    .instr      (imem_data),
    .alu_op     (response.ctrl.alu_op),
    .alu_src    (response.ctrl.alu_src),
    .branch_op  (response.ctrl.branch_op),
    .is_branch  (response.ctrl.is_branch),
    .is_jump    (response.ctrl.is_jump),
    .is_jalr    (response.ctrl.is_jalr),
    .is_lui     (response.ctrl.is_lui),
    .is_auipc   (response.ctrl.is_auipc),
    .mem_read   (response.ctrl.mem_read),
    .mem_write  (response.ctrl.mem_write),
    .mem_width  (response.ctrl.mem_width),
    .mem_sext   (response.ctrl.mem_sext),
    .reg_write  (response.ctrl.reg_write),
    .mem_to_reg (response.ctrl.mem_to_reg),
    .is_mul     (response.ctrl.is_mul),
    .is_div     (response.ctrl.is_div),
    .is_illegal (response.ctrl.is_illegal)
  );

  imm_gen u_imm (.instr(imem_data), .imm(response.imm));

  // The low bits address storage. The wrap bit distinguishes equal
  // addresses at full and empty. Full blocks acceptance through the
  // first pop, and an empty bypass advances both pointers together.
  logic [$bits(response)-1:0] fifo [0:3];
  logic [2:0] read_ptr_q, write_ptr_q;
  logic empty, full;

  assign empty = recovering || read_ptr_q == write_ptr_q;
  assign full  = !recovering && read_ptr_q == {~write_ptr_q[2], write_ptr_q[1:0]};
  assign response_valid = imem_ready && (!aperture_wait_q || recovering);
  assign accept_response = response_valid && !full && !reset;
  assign out = empty ? response : fifo[read_ptr_q[1:0]];
  assign issue_candidate = (!empty || response_valid) && !issue_stall && !reset;
  assign issue = issue_candidate;

  always_ff @(posedge clock) begin
    if (accept_response)
      fifo[write_ptr_q[1:0]] <= response;

    if (reset) begin
      read_ptr_q  <= '0;
      write_ptr_q <= '0;
    end else begin
      // During recovery, the corrected request bypasses the stale FIFO.
      // Rebase at the write pointer while accounting for that response.
      if (recovering)     read_ptr_q  <= write_ptr_q + {2'b0, issue};
      else if (issue)      read_ptr_q  <= read_ptr_q + 3'd1;
      if (accept_response) write_ptr_q <= write_ptr_q + 3'd1;
    end
  end

endmodule
