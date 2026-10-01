// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// The instruction payload always reflects imem_data. Redirects and
// unavailable fetches are represented only by `valid`, keeping redirect
// control off the 32-bit instruction/decode path.
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
  input  logic              predictor_update,
  input  logic [2:0]        predictor_update_index,
  input  logic              predictor_update_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [31:0] fetch_imm;
  logic [31:0] predicted_target;
  logic        predicted_taken;
  logic [1:0]  direction_table [0:7];
  logic [2:0]  fetch_index;

  imm_gen u_predict_imm (.instr(imem_data), .imm(fetch_imm));

  assign fetch_index  = pc[4:2];
  // funct3[2:1] == 2'b01 denotes the two reserved branch encodings.
  // Never speculate them: decode treats those instructions as illegal
  // and EX has no conditional-branch redirect for them.
  assign predicted_taken = (imem_data[6:0] == 7'b1100011)
                        && (imem_data[14:13] != 2'b01)
                        && direction_table[fetch_index][1];
  assign predicted_target = pc + fetch_imm;

  always_comb begin
    next_pc = redirect ? redirect_target
             : predicted_taken ? predicted_target
             : pc + 32'd4;
  end

  // Eight PC-indexed two-bit counters, initialized weakly not-taken.
  // The table stores direction only; each fetch computes a taken target
  // from that instruction's immediate.
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int i = 0; i < 8; i++) direction_table[i] <= 2'b01;
    end else if (predictor_update) begin
      if (predictor_update_taken) begin
        if (direction_table[predictor_update_index] != 2'b11)
          direction_table[predictor_update_index]
            <= direction_table[predictor_update_index] + 2'b01;
      end else begin
        if (direction_table[predictor_update_index] != 2'b00)
          direction_table[predictor_update_index]
            <= direction_table[predictor_update_index] - 2'b01;
      end
    end
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

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.instr = imem_data;
    out.pred_taken = predicted_taken;
    out.pred_target = predicted_target;
    out.valid = !(flush || redirect);
  end

endmodule
