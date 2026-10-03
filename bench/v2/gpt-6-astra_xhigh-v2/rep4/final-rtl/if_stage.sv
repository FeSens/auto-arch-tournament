// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + prediction + valid) is combinational — no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Unavailable imem emits a NOP. Recovery only invalidates the payload:
// ID/EX's synchronous squash clears controls before a wrong-path decode
// can execute, keeping redirect out of the instruction/source-address path.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // fetch not accepted
  input  logic              flush,            // emit NOP into ID this cycle
  input  logic              redirect,         // advancing EX recovery
  input  logic [31:0]       redirect_target,
  input  logic              branch_update,
  // Only the table index bits are needed from the resolving branch PC.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]       branch_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic              branch_taken,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;
  logic [31:0] predicted_next_pc;
  logic        predicted_direct;
  logic [31:0] direct_imm;
  logic [31:0] direct_target;
  logic        legal_branch;
  logic        direct_jump;
  logic [1:0]  counters [0:127];

  // Untagged PC[8:2] bimodal direction table. Read-before-write is fine:
  // both the PC and ID/EX capture the same pre-edge prediction.
  // Update each counter locally: the table needs only its fetch read mux,
  // rather than a second 128-way read mux for the saturating update.
  for (genvar i = 0; i < 128; i++) begin : g_counter
    always_ff @(posedge clock) begin
      if (reset) begin
        counters[i] <= 2'b01;
      end else if (branch_update && branch_pc[8:2] == 7'(i)) begin
        if (branch_taken) begin
          if (counters[i] != 2'b11) counters[i] <= counters[i] + 2'b01;
        end else begin
          if (counters[i] != 2'b00) counters[i] <= counters[i] - 2'b01;
        end
      end
    end
  end

  // Predecode raw memory data, never the flush-generated NOP. The small
  // direct-target adder is independent of EX's forwarded ALU operands.
  always_comb begin
    legal_branch = imem_data[6:0] == 7'b1100011
                && imem_data[14:12] != 3'd2 && imem_data[14:12] != 3'd3;
    direct_jump = imem_data[6:0] == 7'b1101111;
    direct_imm = direct_jump
               ? {{11{imem_data[31]}}, imem_data[31], imem_data[19:12],
                  imem_data[20], imem_data[30:21], 1'b0}
               : {{19{imem_data[31]}}, imem_data[31], imem_data[7],
                  imem_data[30:25], imem_data[11:8], 1'b0};
    direct_target = pc + direct_imm;
    predicted_direct = (direct_jump || (legal_branch && counters[pc[8:2]][1]))
                    && direct_target[1:0] == 2'b00
                    && direct_target[31:20] == 12'b0;
    predicted_next_pc = predicted_direct ? direct_target : pc + 32'd4;
  end

  // Recovery overrides an imem stall. EX defers recovery during a dmem
  // hold. Otherwise consume a prediction only when ID/EX accepts fetch.
  always_ff @(posedge clock) begin
    if      (reset)    pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else if (!stall && !flush) pc <= predicted_next_pc;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.predicted_next_pc = predicted_next_pc;
    out.predicted_direct = predicted_direct;
    out.instr = flush ? 32'h0000_0013 : imem_data;
    out.valid = !(flush || redirect);
  end

endmodule
