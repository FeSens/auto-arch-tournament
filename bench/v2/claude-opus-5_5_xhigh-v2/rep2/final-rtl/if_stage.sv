// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the PC register; the IF/ID payload
// (pc + instr + valid) is *combinational* — there is no separate IF/ID
// flop in this microarchitecture, the next-stage's ID/EX register
// captures everything one cycle later.
//
// The IF word comes from the imem bus when it delivers, else from the
// fetch store (fetch_store.sv) when the word at pc is resident. fetch_ok
// and the store word are flops, so the ID word is one LUT3 of flops.
//
// On flush (!fetch_ok) the word emitted to ID is marked invalid (it is
// not replaced by a NOP). A redirect does not touch `valid`: the
// wrong-path word is squashed one stage later, in EX. The hazard unit
// reads the raw rs fields of both sources; a spurious hit while no word
// is delivered only bubbles ID/EX, which is bubbled anyway.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect), insn.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              stall,            // hold PC (stall_if)
  input  logic              flush,            // mark the IF word invalid this cycle
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  input  logic              imem_ready,
  output logic              fetch_ok,         // IF word valid (bus or store)
  output logic              use_store,        // IF word is the store word
  output logic [31:0]       fword,            // store word (flop)
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  // Fetch-store per-bank index width (4 banks by pc[3:2]): 2^9 x 4 =
  // 2K words for synthesis / simulation, 2 x 4 words under formal.
`ifdef RISCV_FORMAL
  localparam int FS_IDX_W = 1;
`elsif FORMAL
  localparam int FS_IDX_W = 1;
`else
  localparam int FS_IDX_W = 9;
`endif

  logic [31:0] pc;
  logic [31:0] next_pc;
  logic        steer;       // store word predicted taken (flops)
  logic [31:0] tgt;         // its target (adder from flops)

  always_comb begin
    next_pc = steer ? tgt : pc + 32'd4;
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

  fetch_store #(.IDX_W(FS_IDX_W)) u_fs (
    .clock      (clock),
    .reset      (reset),
    .pc         (pc),
    .imem_data  (imem_data),
    .imem_ready (imem_ready),
    .stall      (stall),
    .redirect   (redirect),
    .fetch_ok   (fetch_ok),
    .use_store  (use_store),
    .fword      (fword),
    .steer      (steer),
    .tgt        (tgt)
  );

  // The fetch word goes to ID raw and `valid` only carries !fetch_ok.
  // The wrong-path word behind a redirect is captured normally and
  // killed in EX (ID/EX.squash), so the EX redirect stays off the decode,
  // load-use and ID/EX clear cones. ID/EX sync-clears on !valid
  // (id_stage), so an undelivered word never reaches EX.
  // The store word has priority (use_store is a flop LUT); a steered
  // word carries pred = 1 so ID/EX folds the prediction into EX's
  // redirect selects.
  always_comb begin
    out.pc    = pc;
    out.instr = use_store ? fword : imem_data;
    out.valid = !flush;
    out.pred  = steer;
  end

endmodule
