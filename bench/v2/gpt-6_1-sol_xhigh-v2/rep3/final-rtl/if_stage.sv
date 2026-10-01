// rtl/if_stage.sv
//
// Two fixed circular fetch slots with empty fall-through to ID. Physical
// fetch advances independently of decode; recovery makes old slots
// inaccessible through a preserved one-bit boundary on the following cycle.
//
// Raw instruction predecode and a folded-PC bimodal table predict direct
// transfers. Squashes affect validity alone, keeping recovery out of the
// decoder, regfile addresses and ID/EX payload capture.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold presented head (decode)
  input  logic              flush,            // invalidate fetch this cycle
  input  logic              redirect,         // advancing EX misprediction
  input  logic [31:0]       redirect_target,
  input  logic              train_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       train_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              head_available,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [31:0] cursor_q, recovery_target_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic recovery_pending_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [64:0] slot0_q, slot1_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic head_q, tail_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [1:0] occupancy_q;
  logic [31:0] pc;
  logic effective_head, effective_tail;
  logic [1:0] effective_occupancy;
  logic physical_accept, queue_pop;
  logic [64:0] physical_payload, head_payload;
  logic [31:0] next_pc;
  logic [1:0] counters_q [0:63];
  logic [5:0] fetch_index, train_index;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic train_valid_q, train_taken_q;
  (* syn_preserve = 1, syn_keep = 1, keep = 1, dont_touch = 1 *)
  logic [5:0] train_index_q;
  logic legal_branch, direct_jal, predicted_taken;
  logic [31:0] direct_imm, direct_target;

  assign fetch_index = pc[7:2] ^ pc[13:8];
  assign train_index = train_pc[7:2] ^ train_pc[13:8];

  // Qualified EX events terminate at narrow registers. Consume the prior
  // event exactly once, even during decode/bus holds or pending recovery.
  // Lookup uses the old counter on the update edge; there is no bypass.
  always_ff @(posedge clock) begin
    if (reset) begin
      train_valid_q <= 1'b0;
      train_taken_q <= 1'b0;
      train_index_q <= 6'b0;
      for (int i = 0; i < 64; i++) counters_q[i] <= 2'b01;
    end else begin
      train_valid_q <= train_valid;
      train_taken_q <= train_taken;
      train_index_q <= train_index;
      if (train_valid_q) begin
        if (train_taken_q) begin
          if (counters_q[train_index_q] != 2'b11)
            counters_q[train_index_q] <= counters_q[train_index_q] + 2'b01;
        end else begin
          if (counters_q[train_index_q] != 2'b00)
            counters_q[train_index_q] <= counters_q[train_index_q] - 2'b01;
        end
      end
    end
  end

  always_comb begin
    legal_branch = imem_data[6:0] == 7'h63 &&
                   (imem_data[14:12] == 3'd0 || imem_data[14:12] == 3'd1 ||
                    imem_data[14:12] == 3'd4 || imem_data[14:12] == 3'd5 ||
                    imem_data[14:12] == 3'd6 || imem_data[14:12] == 3'd7);
    direct_jal = imem_data[6:0] == 7'h6f;
    direct_imm = direct_jal
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = (direct_jal || (legal_branch && counters_q[fetch_index][1]))
                      && direct_target[1:0] == 2'b00
                      && direct_target[31:20] == 12'b0;
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  assign pc = recovery_pending_q ? recovery_target_q : cursor_q;
  assign effective_occupancy = recovery_pending_q ? 2'b0 : occupancy_q;
  assign effective_head = recovery_pending_q ? 1'b0 : head_q;
  assign effective_tail = recovery_pending_q ? 1'b0 : tail_q;
  // Full admission intentionally waits an edge after a pop. Neither
  // downstream holds nor this cycle's redirect qualify physical writes.
  assign physical_accept = imem_ready && effective_occupancy < 2 && !reset;
  assign head_available = effective_occupancy != 0 || imem_ready;
  assign queue_pop = head_available && !stall && !reset;
  assign physical_payload = {pc, imem_data, predicted_taken};
  assign head_payload = effective_occupancy != 0
                        ? (effective_head ? slot1_q : slot0_q)
                        : physical_payload;

  always_ff @(posedge clock) begin
    if (reset) begin
      cursor_q <= RESET_PC;
      recovery_target_q <= RESET_PC;
      recovery_pending_q <= 1'b0;
      head_q <= 1'b0;
      tail_q <= 1'b0;
      occupancy_q <= 2'b0;
      slot0_q <= 65'b0;
      slot1_q <= 65'b0;
    end else begin
      if (physical_accept) cursor_q <= next_pc;
      // Capture the candidate independently of the late comparison. A
      // blocked correction retains its full-width target until accepted.
      if (!recovery_pending_q || physical_accept)
        recovery_target_q <= redirect_target;
      if (redirect) recovery_pending_q <= 1'b1;
      else if (physical_accept) recovery_pending_q <= 1'b0;

      head_q <= effective_head ^ queue_pop;
      tail_q <= effective_tail ^ physical_accept;
      case ({physical_accept, queue_pop})
        2'b10: occupancy_q <= effective_occupancy + 2'd1;
        2'b01: occupancy_q <= effective_occupancy - 2'd1;
        default: occupancy_q <= effective_occupancy;
      endcase
      if (physical_accept && !effective_tail) slot0_q <= physical_payload;
      if (physical_accept && effective_tail) slot1_q <= physical_payload;
    end
  end

`ifdef RISCV_FORMAL
  always_ff @(posedge clock) begin
    if (!reset) begin
      assert (occupancy_q <= 2);
      // Immediate EX squash leaves no younger executable token until
      // corrected fetch acceptance. Never mask a new live correction.
      assert (!(redirect && recovery_pending_q && !physical_accept));
    end
  end
`endif

  assign imem_addr = pc;

  assign out.pc = head_payload[64:33];
  assign out.instr = head_payload[32:1];
  assign out.predicted_taken = head_payload[0] && !reset;
  assign out.valid = head_available && !(reset || flush || redirect);

endmodule
