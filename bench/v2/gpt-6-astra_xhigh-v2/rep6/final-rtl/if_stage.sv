// rtl/if_stage.sv
//
// Two-entry fall-through instruction ring. The fetch PC and prediction
// lookup advance on bus acceptance, independently of decode's backend hold.
// Only instructions and fetch-time predictions are queued; operands resolve
// at issue. Recovery clears metadata and annuls the next X slot separately.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // backend hold, excluding imem
  input  logic              redirect,         // accepted EX prediction recovery
  input  logic [31:0]       redirect_target,
  input  logic              branch_update_valid,
  input  logic [3:0]        branch_update_index,
  input  logic              branch_update_agree,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [15:0] agree_msb;
  logic legal_branch, direct_jump, predicted_taken;
  logic [31:0] direct_imm, direct_target;
  logic [64:0] slots [0:1];
  logic [64:0] live_tuple, head;
  logic [1:0] count;
  logic read_slot, write_slot;
  logic pop, push, fetch_accept;

  assign live_tuple = {pc, imem_data, predicted_taken};
  assign head = ({65{count != 0 && !read_slot}} & slots[0])
              | ({65{count != 0 &&  read_slot}} & slots[1])
              | ({65{count == 0}} & live_tuple);
  assign pop = count != 0 && !stall;
  assign fetch_accept = imem_ready && (count != 2 || pop);
  assign push = fetch_accept && (count != 0 || stall);

  // Full pop/push reads the old head before replacing the same slot.
  // Reset/recovery discard any simultaneous write by clearing metadata;
  // payload enables and data never depend on recovery.
  always_ff @(posedge clock) begin
    if (push) slots[write_slot] <= live_tuple;
    if (reset || redirect) begin
      count <= 2'd0;
      read_slot <= 1'b0;
      write_slot <= 1'b0;
    end else begin
      if (pop) read_slot <= !read_slot;
      if (push) write_slot <= !write_slot;
      case ({push, pop})
        2'b10: count <= count + 2'd1;
        2'b01: count <= count - 2'd1;
        default: ;
      endcase
    end
  end

  // Each cell reads only its own state for training. Only MSBs enter
  // the asynchronous lookup; a simultaneous update is read-before-write.
  for (genvar i = 0; i < 16; i++) begin : g_agree
    logic [1:0] counter;
    logic [1:0] counter_next;
    assign agree_msb[i] = counter[1];
    // Unsigned saturating increment/decrement, with local two-bit logic.
    assign counter_next = branch_update_agree
                        ? {counter[1] | counter[0], counter[1] | ~counter[0]}
                        : {counter[1] & counter[0], counter[1] & ~counter[0]};
    always_ff @(posedge clock) begin
      if (reset) counter <= 2'b10;
      else if (branch_update_valid && branch_update_index == 4'(i))
        counter <= counter_next;
    end
  end

  // Predecode the raw bus word, never the flush-masked ID instruction:
  // recovery and load-use hazards must not feed back into prediction.
  always_comb begin
    legal_branch = imem_data[6:0] == 7'b1100011
                && imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3;
    direct_jump = imem_data[6:0] == 7'b1101111;
    direct_imm = direct_jump
               ? {{12{imem_data[31]}}, imem_data[19:12], imem_data[20],
                  imem_data[30:21], 1'b0}
               : {{20{imem_data[31]}}, imem_data[7], imem_data[30:25],
                  imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = (direct_jump ||
                       (legal_branch && (imem_data[31] == agree_msb[pc[5:2]])))
                    && direct_target[1:0] == 2'b00;
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  // Accepted recovery repairs PC even while the instruction bus waits.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (fetch_accept) pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    {out.pc, out.instr, out.predicted_taken} = head;
    out.valid = count != 0 || imem_ready;
  end

endmodule
