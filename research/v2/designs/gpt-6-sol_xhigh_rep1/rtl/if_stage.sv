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
  logic [31:0] pc_plus_four;
  logic [31:0] next_pc;
  logic [8:0]  low_target_sum;
  logic        predict_taken;
  logic        short_offset;

  always_comb begin
    pc_plus_four = pc + 32'd4;
    // B immediate [7:0] is {inst[27:25], inst[11:8], 1'b0}.
    // Prediction deliberately does not depend on the carry or the signed
    // eight-bit range check. EX repairs guesses that leave this block.
    low_target_sum = {1'b0, pc[7:0]} +
                     {1'b0, imem_data[27:25], imem_data[11:8], 1'b0};
    // Sign bit 7 of the eight-bit offset is B-imm[7] = instr[27].
    short_offset = imem_data[7] && (&imem_data[30:27]);
    predict_taken = !flush && !redirect &&
                    (imem_data[6:0] == 7'b1100011) && imem_data[31] &&
                    !imem_data[8] && (pc[7:0] != 8'hfc);
    // The high PC bits always use the old sequential path. For a negative
    // short offset the target stays in this block exactly when the low-byte
    // addition carries, checked after the ID/EX register in EX.
    next_pc = {pc_plus_four[31:8],
               predict_taken ? low_target_sum[7:0] : pc_plus_four[7:0]};
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
    out.predicted_taken = predict_taken;
    out.predicted_carry = predict_taken && low_target_sum[8];
    out.predicted_short = predict_taken && short_offset;
    out.valid = !(flush || redirect);
  end

endmodule
