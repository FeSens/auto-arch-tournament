// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Instruction bits always come directly from imem, including on a
// redirect or unavailable fetch. Only valid is squashed; ID clears the
// bubble's controls so it cannot write registers, access memory, or
// create a load-use hazard. This keeps redirect out of decode/read data.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (load-use)
  input  logic              flush,            // invalidate fetch this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic             agreement,
  output logic [3:0]       lookup_index,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic legal_branch, legal_jal, bias, predict_b, predict_j;
  logic accepted, hold_pc, sequential_pc, branch_pc, jump_pc;
  logic [31:0] pc_plus4, b_target, j_target;
  logic [12:0] b_low_sum;
  logic [20:0] j_low_sum;
  logic [19:0] b_high_up, b_high_down, b_high;
  logic [11:0] j_high_up, j_high_down, j_high;
  logic [31:0] hold_term, sequential_term, branch_term, jump_term, repair_term;

  assign lookup_index = pc[5:2] ^ pc[10:7];
  assign legal_branch = (imem_data[6:0] == 7'b1100011) &&
                        (imem_data[14] || !imem_data[13]);
  assign legal_jal = (imem_data[6:0] == 7'b1101111);
  assign bias = imem_data[14] ? imem_data[31] : imem_data[12];

  // Exact modulo-2^32 direct additions. Carry == sign cancels the
  // sign extension; otherwise select a parallel upper increment/decrement.
  assign b_low_sum = {1'b0, pc[11:0]} +
                     {1'b0, imem_data[7], imem_data[30:25], imem_data[11:8], 1'b0};
  assign b_high_up = pc[31:12] + 20'd1;
  assign b_high_down = pc[31:12] - 20'd1;
  assign b_high = (b_low_sum[12] == imem_data[31]) ? pc[31:12]
                : b_low_sum[12] ? b_high_up : b_high_down;
  assign b_target = {b_high, b_low_sum[11:0]};
  assign j_low_sum = {1'b0, pc[19:0]} +
                     {1'b0, imem_data[19:12], imem_data[20], imem_data[30:21], 1'b0};
  assign j_high_up = pc[31:20] + 12'd1;
  assign j_high_down = pc[31:20] - 12'd1;
  assign j_high = (j_low_sum[20] == imem_data[31]) ? pc[31:20]
                : j_low_sum[20] ? j_high_up : j_high_down;
  assign j_target = {j_high, j_low_sum[19:0]};
  assign pc_plus4 = pc + 32'd4;

  assign predict_b = legal_branch && (b_target[1:0] == 2'b00) && (bias ^ !agreement);
  assign predict_j = legal_jal && (j_target[1:0] == 2'b00);
  assign accepted = !stall && !flush;
  assign hold_pc = !redirect && !accepted;
  assign sequential_pc = !redirect && accepted && !(predict_b || predict_j);
  assign branch_pc = !redirect && accepted && predict_b;
  assign jump_pc = !redirect && accepted && predict_j;
  assign hold_term = pc & {32{hold_pc}};
  assign sequential_term = pc_plus4 & {32{sequential_pc}};
  assign branch_term = b_target & {32{branch_pc}};
  assign jump_term = j_target & {32{jump_pc}};
  assign repair_term = redirect_target & {32{redirect}};
  assign next_pc = ((hold_term | sequential_term) | (branch_term | jump_term)) | repair_term;

  // Complete successor is registered each clock; accepted repair wins
  // over imem/load-use holds without a late PC clock-enable mux.
  always_ff @(posedge clock) begin
    if (reset) pc <= RESET_PC;
    else       pc <= next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = imem_data;
    out.predicted_taken = predict_b || predict_j;
    out.valid = !(flush || redirect);
  end

`ifndef SYNTHESIS
  always @(posedge clock) begin
    if (!reset) begin
      assert (b_target == pc + {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                                imem_data[30:25], imem_data[11:8], 1'b0});
      assert (j_target == pc + {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                                imem_data[20], imem_data[30:21], 1'b0});
      if (accepted && !redirect && out.predicted_taken)
        assert ((legal_branch && b_target[1:0] == 2'b00) ||
                (legal_jal && j_target[1:0] == 2'b00));
    end
  end
`endif

endmodule
