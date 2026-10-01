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
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic [12:0] branch_imm_low;
  logic [13:0] branch_low_sum;
  logic        branch_inc_hi;
  logic        branch_dec_hi;
  logic [18:0] branch_target_hi;
  logic [31:0] branch_target;
  logic        valid_branch;
  logic        predicted_taken;

  always_comb begin
    branch_imm_low = {imem_data[31], imem_data[7], imem_data[30:25],
                      imem_data[11:8], 1'b0};
    branch_low_sum = {1'b0, pc[12:0]} + {1'b0, branch_imm_low};
    branch_inc_hi = branch_low_sum[13] && !imem_data[31];
    branch_dec_hi = !branch_low_sum[13] && imem_data[31];
    branch_target_hi[0] = pc[13] ^ branch_inc_hi ^ branch_dec_hi;
    valid_branch = (imem_data[6:0] == 7'b1100011) &&
                   (imem_data[14:12] != 3'b010) &&
                   (imem_data[14:12] != 3'b011);
    predicted_taken = valid_branch && imem_data[31] &&
                      (branch_low_sum[1:0] == 2'b00) &&
                      !flush && !redirect;
    branch_target = {branch_target_hi, branch_low_sum[12:0]};
    next_pc = redirect ? redirect_target
            : predicted_taken ? branch_target
            : pc + 32'd4;
  end

  for (genvar target_bit = 1; target_bit < 19; target_bit++) begin : gen_branch_target_hi
    assign branch_target_hi[target_bit] = pc[13 + target_bit] ^
      ((branch_inc_hi && (&pc[13 +: target_bit])) ||
       (branch_dec_hi && (~|pc[13 +: target_bit])));
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
    out.instr = (flush || redirect) ? 32'h0000_0013 : imem_data;
    out.predicted_taken = predicted_taken;
    out.valid = !(flush || redirect);
  end

endmodule
