// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// The instruction emitted to ID is the raw imem word: there is no NOP mux
// on redirect, so the regfile read addresses, the decoder, imm_gen and the
// load-use compare never depend on the EX redirect. A wrong-path or
// not-ready word only clears `valid` (imem stall) or is killed in ID/EX
// (flush_id for a jump, the take_kill D-term for a taken branch). A
// load-use stall that such a word raises falsely is harmless: redirect
// overrides the PC hold, and the word is never captured.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              hold,             // hold PC (stall && !jump)
  input  logic              flush,            // imem did not deliver: valid=0
  // EX redirect controls. take is the late branch condition (one copy per
  // PC byte); the rest are registered (ID/EX) or come off the AGU chain.
  input  logic [3:0]        take,             // BRANCH mispredicted in EX (PC[8i+7:8i])
  input  logic [31:0]       br_target,        // BRANCH / JAL target
  input  logic              jump,             // JAL / JALR / p_bad in EX
  input  logic              jlink,            // ... and its target is link
  input  logic              p_ok_lo,          // EX branch was predicted taken:
  input  logic              p_ok_hi,          //   take goes to link (lo/hi copies)
  input  logic [29:0]       inc,              // fetch_pred inc_q (flop)
  output logic [11:2]       pc_alt_o,         // pc_alt, for fetch_pred idx_q
  input  logic              jalr_go,          // aligned JALR: go to agu_target
  input  logic [31:0]       agu_target,       // JALR target {sum[31:1], 0}
  input  logic [31:0]       link,             // JALR misaligned: pc + 4
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc;

  // PC next state is a plain D mux, with the branch condition as the
  // last select (no clock enable or priority chain behind it):
  //   pc_reg : registers only (jump target / pc + inc_q, where inc_q is
  //            the predictor's registered increment: 1 or a predicted
  //            taken B/J offset)
  //   pc_alt : hold ? pc : pc_reg, hold = stall && !jump (one 2:1 select
  //            after the stall)
  //   pc_nt  : not-taken next PC (aligned JALR overrides from the AGU)
  //   pc_d   : take ? ex_tgt : pc_nt (one take copy per PC byte), with
  //            ex_tgt = p_ok ? link : br_target (flops only)
  // Redirect overrides stall: a BRANCH/JAL/JALR in EX may redirect on the
  // same cycle as imem_stall or dmem_stall — without this priority the
  // target would be silently dropped and execution would resume on the
  // wrong path once the bus unstalls. A JALR whose target is misaligned
  // traps and continues at pc + 4 (link).
  logic [31:0] pc_reg /* synthesis syn_keep=1 */;
  logic [31:0] pc_alt /* synthesis syn_keep=1 */;
  logic [31:0] pc_nt  /* synthesis syn_keep=1 */;
  logic [31:0] pc_d;
  logic [31:0] jtgt   /* synthesis syn_keep=1 */;
  logic [31:0] ex_tgt /* synthesis syn_keep=1 */;

  // Next sequential / predicted fetch: pc[31:2] + inc_q on the carry
  // chain (inc_q is a flop, so the chain has the same cell structure as
  // a kept constant-1 operand).
  logic [31:0] pc_inc;
  assign pc_inc = {pc[31:2] + inc, pc[1:0]};

  // ID's link needs plain pc + 4: a separate carry-chain incrementer on a
  // kept constant-1 operand (synthesis cannot fold it into a LUT ripple
  // incrementer). Off the PC loop; feeds only IF/ID.pc4.
  logic [29:0] inc_one /* synthesis syn_keep=1 */;
  logic [31:0] pc4;

  assign inc_one = 30'd1;
  assign pc4     = {pc[31:2] + inc_one, pc[1:0]};

  always_comb begin
    jtgt         = jlink ? link : br_target;
    ex_tgt[15:0]  = p_ok_lo ? link[15:0]  : br_target[15:0];
    ex_tgt[31:16] = p_ok_hi ? link[31:16] : br_target[31:16];
    pc_reg       = jump ? jtgt : pc_inc;
    pc_alt       = hold ? pc : pc_reg;
    pc_nt        = jalr_go ? agu_target : pc_alt;
    for (int i = 0; i < 4; i++) begin
      pc_d[8*i +: 8] = take[i] ? ex_tgt[8*i +: 8] : pc_nt[8*i +: 8];
    end
  end

  assign pc_alt_o = pc_alt[11:2];

  always_ff @(posedge clock) begin
    if (reset) pc <= RESET_PC;
    else       pc <= pc_d;
  end

  assign imem_addr = pc;

  always_comb begin
    out.pc    = pc;
    out.pc4   = pc4;
    out.instr = imem_data;
    out.valid = !flush;
  end

endmodule
