// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// On flush or redirect, the instruction emitted to ID is forced to NOP
// (`0x00000013` = ADDI x0,x0,0). This prevents the hazard unit from
// observing a real rs1/rs2 from a wrong-path instruction and inserting
// a spurious load-use stall the cycle after a taken branch.
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
  // Resolved backward-branch outcomes train the small loop table.
  input  logic              loop_update_valid,
  input  logic [31:0]       loop_update_pc,
  input  logic              loop_update_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] fetch_branch_imm;
  logic        fetch_is_branch;
  logic        fetch_is_backward;
  logic        fetch_pred_taken;
  logic [1:0]  fetch_idx;
  logic [1:0]  update_idx;

  // Four direct-mapped entries, tagged with the complete branch PC. The
  // per-entry iteration counter counts taken outcomes in the current loop
  // invocation. Twelve bits cover ordinary software loops; saturation
  // disables the learned exit prediction for longer loops.
  localparam logic [11:0] LOOP_COUNT_MAX = 12'hfff;
  logic        loop_valid_q [0:3];
  logic [31:0] loop_tag_q [0:3];
  logic [11:0] loop_trip_q [0:3];
  logic [11:0] loop_count_q [0:3];
  logic [1:0]  loop_conf_q [0:3];

  always_comb begin
    fetch_branch_imm = {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                        imem_data[30:25], imem_data[11:8], 1'b0};
    fetch_is_branch = (imem_data[6:0] == 7'b1100011) &&
                      (imem_data[14:12] == 3'd0 ||
                       imem_data[14:12] == 3'd1 ||
                       imem_data[14:12] == 3'd4 ||
                       imem_data[14:12] == 3'd5 ||
                       imem_data[14:12] == 3'd6 ||
                       imem_data[14:12] == 3'd7) && !flush && !redirect;
    fetch_is_backward = fetch_branch_imm[31];
    fetch_idx = pc[3:2];
    // Static backward-taken / forward-not-taken prediction is the cold
    // fallback. A confident loop entry predicts NT after its learned
    // number of taken iterations in this invocation.
    fetch_pred_taken = fetch_is_branch && fetch_is_backward;
    if (fetch_is_branch && fetch_is_backward &&
        loop_valid_q[fetch_idx] && loop_tag_q[fetch_idx] == pc &&
        loop_conf_q[fetch_idx] >= 2'd2 &&
        loop_count_q[fetch_idx] != LOOP_COUNT_MAX &&
        loop_trip_q[fetch_idx] != LOOP_COUNT_MAX) begin
      fetch_pred_taken = (loop_count_q[fetch_idx] != loop_trip_q[fetch_idx]);
    end

    next_pc = redirect ? redirect_target :
              (fetch_pred_taken ? (pc + fetch_branch_imm) : (pc + 32'd4));
    update_idx = loop_update_pc[3:2];
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

  // Train only on resolved outcomes from EX. A changed trip count becomes
  // one matching observation; two matching completed invocations establish
  // confidence, while further matches saturate the confidence counter.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 4; i++) begin
        loop_valid_q[i] <= 1'b0;
        loop_tag_q[i] <= 32'b0;
        loop_trip_q[i] <= 12'b0;
        loop_count_q[i] <= 12'b0;
        loop_conf_q[i] <= 2'b0;
      end
    end else if (loop_update_valid) begin
      if (!loop_valid_q[update_idx] ||
          loop_tag_q[update_idx] != loop_update_pc) begin
        loop_valid_q[update_idx] <= 1'b1;
        loop_tag_q[update_idx] <= loop_update_pc;
        loop_trip_q[update_idx] <= 12'b0;
        loop_conf_q[update_idx] <= loop_update_taken ? 2'b0 : 2'b1;
        loop_count_q[update_idx] <= loop_update_taken ? 12'd1 : 12'b0;
      end else if (loop_update_taken) begin
        if (loop_count_q[update_idx] != LOOP_COUNT_MAX)
          loop_count_q[update_idx] <= loop_count_q[update_idx] + 12'd1;
      end else begin
        if (loop_conf_q[update_idx] == 2'b0) begin
          loop_trip_q[update_idx] <= loop_count_q[update_idx];
          loop_conf_q[update_idx] <= 2'b1;
        end else if (loop_trip_q[update_idx] == loop_count_q[update_idx]) begin
          if (loop_conf_q[update_idx] != 2'b11)
            loop_conf_q[update_idx] <= loop_conf_q[update_idx] + 2'd1;
        end else begin
          loop_trip_q[update_idx] <= loop_count_q[update_idx];
          loop_conf_q[update_idx] <= 2'b1;
        end
        loop_count_q[update_idx] <= 12'b0;
      end
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = (flush || redirect) ? 32'h0000_0013 : imem_data;
    out.pred_taken = fetch_pred_taken;
    out.valid = !(flush || redirect);
  end

endmodule
