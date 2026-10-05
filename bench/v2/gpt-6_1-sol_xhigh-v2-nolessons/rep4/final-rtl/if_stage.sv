// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Raw-instruction predecode predicts aligned branches and JALs. The
// validated ID decoder remains the authority for legality and effects.
// Prediction is consumed only when ID/EX captures this exact instruction.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              accept,           // instruction captured into ID/EX
  input  logic              flush,            // invalidate fetched instruction
  input  logic              redirect,         // advancing EX repair
  input  logic [31:0]       redirect_target,
  input  logic              branch_train_en,
  input  logic [5:0]        branch_train_index,
  input  logic              branch_train_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [1:0] direction_q [0:63];
  logic is_branch, is_jal, predicted_taken;
  logic [31:0] direct_imm, direct_target;

  always_comb begin
    is_branch = imem_data[6:0] == 7'h63 &&
                (imem_data[14:12] == 3'd0 || imem_data[14:12] == 3'd1 ||
                 imem_data[14:12] == 3'd4 || imem_data[14:12] == 3'd5 ||
                 imem_data[14:12] == 3'd6 || imem_data[14:12] == 3'd7);
    is_jal = imem_data[6:0] == 7'h6f;
    direct_imm = is_jal
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_taken = direct_target[1:0] == 2'b00 &&
                      (is_jal || (is_branch && direction_q[pc[7:2]][1]));
    next_pc = predicted_taken ? direct_target : pc + 32'd4;
  end

  // EX gates repair and training on MEM acceptance. An advancing repair
  // overrides frontend holds and discards the one younger instruction.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (accept)   pc <= next_pc;
  end

  // Nonblocking writes leave the accepting edge's prediction based on
  // the pre-edge value, including same-index reads and training writes.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 64; i++) direction_q[i] <= 2'b10;
    end else if (branch_train_en) begin
      if (branch_train_taken) begin
        if (direction_q[branch_train_index] != 2'b11)
          direction_q[branch_train_index] <= direction_q[branch_train_index] + 2'b01;
      end else begin
        if (direction_q[branch_train_index] != 2'b00)
          direction_q[branch_train_index] <= direction_q[branch_train_index] - 2'b01;
      end
    end
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = imem_data;
    out.predicted_taken = predicted_taken;
    out.valid = !flush;
  end

endmodule
