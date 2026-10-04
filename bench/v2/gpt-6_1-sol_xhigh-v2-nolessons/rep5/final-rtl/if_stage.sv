// rtl/if_stage.sv
//
// Predicted fetch producer with a single-entry instruction skid buffer.
// An empty buffer bypasses the raw producer payload directly to decode.
// A ready response can fill the buffer while the consumer is held; a full
// buffer can dequeue even when the producer bus is unready.
//
// Only registered occupancy selects the wide decode payload. Correction
// kills eligibility without changing the selected instruction or operands.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold consumer (load-use/backend)
  input  logic              flush,            // suppress ID acceptance this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic             imem_ready,        // raw producer response qualification
  input  logic             predicted_taken,
  output logic             available,         // raw consumer availability
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] direct_imm, direct_target, fallthrough_pc, recovery_pc;
  logic legal_branch, legal_jal, safe_direct, predicted_transfer;
  if_id_t producer, buffer_q;
  logic full_q;
  logic consume, pop, direct, push;

  always_comb begin
    legal_branch = 1'b0;
    if (imem_data[6:0] == 7'b1100011) begin
      case (imem_data[14:12])
        3'd0, 3'd1, 3'd4, 3'd5, 3'd6, 3'd7: legal_branch = 1'b1;
        default: ;
      endcase
    end
    legal_jal = imem_data[6:0] == 7'b1101111;
    // Bit 3 distinguishes positively validated BRANCH and JAL. Raw
    // target preparation needs no full opcode decode in front of its
    // adder; non-control payload targets cannot have an architectural use.
    direct_imm = imem_data[3]
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    fallthrough_pc = pc + 32'd4;
    safe_direct = pc[1:0] == 2'b00 && direct_target[1:0] == 2'b00
                  && pc[31:20] == 12'b0 && !direct_target[20];
    // With an in-range source, B/J displacement is in [-2^20,2^20),
    // so bit 20 alone detects both underflow and overflow of this range.
    // Keep the entire modular target for EX and architectural retirement.
    predicted_transfer = safe_direct && (legal_jal || (legal_branch && predicted_taken));
    // Select the complementary successor before ID/EX, from the admitted
    // prediction. EX resolution must never select this address.
    recovery_pc = predicted_transfer ? fallthrough_pc : direct_target;
    next_pc = predicted_transfer ? {12'b0, direct_target[19:0]} : fallthrough_pc;
  end

  assign available = full_q || imem_ready;
  assign consume = !stall && !flush && !redirect;
  assign pop = full_q && consume;
  assign direct = !full_q && imem_ready && consume;
  assign push = imem_ready && (!full_q || pop) && !redirect;

  // Payload capture is independent of accepted correction. An empty
  // direct bypass may also update this unused register, and a correction
  // may capture discarded raw data while clearing occupancy below. In
  // core, flush is redirect OR absent availability; with imem_ready high,
  // (redirect OR !flush) is always true. Keep correction off the wide
  // payload enable while retaining flush-only holds at this interface.
  always_ff @(posedge clock) begin
    if (reset) buffer_q <= '0;
    else if (imem_ready && (!full_q || (!stall && (redirect || !flush))))
      buffer_q <= producer;
  end

  // Every accepted raw word advances the producer using that word's saved
  // prediction, independently of whether decode consumes it on this edge.
  // Correction overrides holds and discards all queued wrong-path work.
  always_ff @(posedge clock) begin
    if (reset) begin
      pc <= RESET_PC;
      full_q <= 1'b0;
    end else if (redirect) begin
      pc <= redirect_target;
      full_q <= 1'b0;
    end else begin
      if (push) pc <= next_pc;
      if (push && !direct) begin
        full_q <= 1'b1;
      end else if (pop) begin
        full_q <= 1'b0;
      end
    end
  end

  assign imem_addr = pc;

  always_comb begin
    producer.pc = pc;
    producer.instr = imem_data;
    producer.direct_target = direct_target;
    producer.fallthrough_pc = fallthrough_pc;
    producer.predicted_transfer = predicted_transfer;
    producer.recovery_pc = recovery_pc;
    producer.valid = 1'b1;

    out = full_q ? buffer_q : producer;
    out.valid = available && !(flush || redirect);
  end

endmodule
