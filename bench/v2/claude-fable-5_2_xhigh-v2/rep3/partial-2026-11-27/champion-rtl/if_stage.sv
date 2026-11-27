// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// Zero-bubble redirect: the EX redirect target drives the FETCH ADDRESS
// in the very cycle the branch / jump resolves,
//   imem_addr = redirect ? redirect_target : seq_addr
// so the target word is fetched, decoded and captured into ID/EX in that
// same cycle and nothing wrong-path is ever fetched. The address is a
// function of registers only (redirect / redirect_target come from the
// ID/EX flops); bus stalls act only on the pc_q / skip_q update.
//
//   pc_q   : address of the next word to deliver, unless skip_q
//   skip_q : the word at pc_q was already delivered to ID in the
//            redirect cycle, so the sequential fetch address is pc_q + 4
//   seq_addr = pc_q + (skip_q ? 4 : 0)      flops only
//   seq_next = pc_q + (skip_q ? 8 : 4)      flops only
//   redirect : pc_q <= redirect_target, skip_q <= target word consumed
//   !stall   : pc_q <= seq_next,        skip_q <= 0
//   else     : hold
// The late `redirect` stays a pure 2:1 select in front of pc_q (no
// incrementer behind the branch compare).
//
// `redirect_kill` (raw instr[2] of the fetched word in the shipped
// build, see core.sv ZB_PC_LEG_LATE): the target word is NOT consumed in
// the redirect cycle (hazard_unit bubbles ID/EX), so it has to be
// fetched again from pc_q. It only gates skip_q, never the address.
//
// The fetched word is passed to ID RAW; an undelivered word (imem
// stall) is killed at the ID/EX register (hazard_unit's id_bubble).
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (no word consumed); valid when !redirect
  input  logic              stall_red,        // redirect cycle: target word not delivered / not captured
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              redirect_kill,    // redirect cycle: target word not consumed
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,       // bus delivers imem_data this cycle
  input  logic              flush,            // FENCE decoded: flush the replay table
  output logic              pw_hit,           // replay word available for seq_addr (flop)
  output logic [31:0]       seq_pc,           // sequential fetch address (flops only)
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] pc_q;
  logic        skip_q;
  logic [31:0] seq_addr;
  logic [31:0] seq_next;

  always_comb begin
    seq_addr = pc_q + {29'b0, skip_q, 2'b00};
    seq_next = pc_q + {28'b0, skip_q, !skip_q, 2'b00};
  end

  // Redirect overrides stall: a BRANCH/JAL/JALR in EX may fire redirect
  // on the same cycle as an imem or dmem stall. pc_q then takes the
  // target with skip_q = 0, so the target is (re)fetched from pc_q:
  //   imem stall : the branch leaves EX, ID/EX gets a bubble
  //   dmem stall : the branch stays in EX and re-asserts the same
  //                redirect next cycle (idempotent)
  always_ff @(posedge clock) begin
    if (reset) begin
      pc_q   <= RESET_PC;
      skip_q <= 1'b0;
    end else if (redirect) begin
      pc_q   <= redirect_target;
      skip_q <= !stall_red && !redirect_kill;
    end else if (!stall) begin
      pc_q   <= seq_next;
      skip_q <= 1'b0;
    end
  end

  assign imem_addr = redirect ? redirect_target : seq_addr;
  assign seq_pc    = seq_addr;

  // ── Fetch replay table (stall-hiding next-fetch word predictor) ───────
  // pw_word is the table's word for seq_addr, looked up one cycle ahead
  // under the key {skip_q, pc_q} (flops only: the entry stored under a
  // fetch state is the word at that state's seq_next). It substitutes for the bus word only when the bus stalls;
  // the select is the bus handshake input, never `redirect`. In a
  // redirect cycle with a stalled bus the (sequential-path) replay word
  // is not the target: hazard_unit bubbles it (fetch_ok = 0).
  logic [31:0] pw_word;

  fetch_pred u_pred (
    .clock      (clock),
    .reset      (reset),
    .pc         (pc_q),
    .skip       (skip_q),
    .redirect   (redirect),
    .advance    (!stall),
    .flush      (flush),
    .imem_ready (imem_ready),
    .imem_data  (imem_data),
    .pw_hit     (pw_hit),
    .pw_word    (pw_word)
  );

  always_comb begin
    out.pc    = imem_addr;   // pc of the word fetched this cycle
    // raw; kill is applied at ID/EX (id_bubble)
    out.instr = imem_ready ? imem_data : pw_word;
    out.valid = 1'b1;
  end

endmodule
