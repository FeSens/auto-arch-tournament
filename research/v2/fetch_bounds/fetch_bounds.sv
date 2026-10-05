// Fetch-address bounds check for a V2 core (research side, exploratory).
//
// Property: on every cycle after reset, io_imemAddr is inside the 1 MiB
// memory, the rule test/cosim/main.cpp applies to every cycle
// (CLAUDE.md invariant 6) and that no V2 gate checks formally.
//
// Environment: a fixed but arbitrary program of N words at addresses
// [0, CODE_TOP) (the same word every time an address is fetched, as in a real
// memory), constrained only so that the program itself never leaves that
// region on any path:
//   - a conditional branch or JAL targets a 4-byte-aligned address in
//     [0, CODE_TOP);
//   - JALR only with rs1 = x0 and an aligned offset below CODE_TOP; a
//     register-indirect JALR is excluded because its target is data the
//     environment cannot bound;
//   - no SYSTEM instruction (EBREAK halts the cosim run; ECALL/CSR trap).
// A fetch at or above CODE_TOP (only a wrong-path or sequential prefetch can
// get there within the BMC depth) returns `jal x0, 0`. So an out-of-range
// fetch address can only come from the core itself: a mispredicted or
// miscomputed target (for example an aliased predictor entry applied to a
// PC near 0, the Opus 5.5 rep6 case), not from the program. Data memory and
// both ready signals are free (stalls included, unlike the gate's formal
// wrapper, which ties ready to 1). State starts at zero (the flow maps
// memories to flip-flops and zero-initializes every flip-flop, as Verilator
// does); reset is held for the first two cycles.
module fetch_bounds_top (input clock);
    localparam integer N = 64;
    localparam [31:0] MEM_SIZE = 32'h0010_0000;
    localparam [31:0] CODE_TOP = N * 4;

    reg [1:0] rcnt = 2'd0;
    wire reset = rcnt != 2'd2;
    always @(posedge clock) if (rcnt != 2'd2) rcnt <= rcnt + 2'd1;

    (* anyconst *) reg [N*32-1:0] prog;
    (* anyseq *) wire [31:0] dmem_rdata;
    (* anyseq *) wire        imem_ready;
    (* anyseq *) wire        dmem_ready;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wen;
    wire        dmem_ren;
    wire [31:0] imem_data = imem_addr < CODE_TOP ? prog[imem_addr[7:2]*32 +: 32] : 32'h0000006f;

    core uut (
        .clock(clock), .reset(reset),
        .io_imemAddr(imem_addr), .io_imemData(imem_data), .io_imemReady(imem_ready),
        .io_dmemAddr(dmem_addr), .io_dmemWData(dmem_wdata), .io_dmemRData(dmem_rdata),
        .io_dmemWEn(dmem_wen), .io_dmemREn(dmem_ren), .io_dmemReady(dmem_ready)
    );

    genvar i;
    generate for (i = 0; i < N; i = i + 1) begin : words
        wire [31:0] w = prog[i*32 +: 32];
        wire [31:0] imm_b = {{20{w[31]}}, w[7], w[30:25], w[11:8], 1'b0};
        wire [31:0] imm_j = {{12{w[31]}}, w[19:12], w[20], w[30:21], 1'b0};
        wire [31:0] imm_i = {{20{w[31]}}, w[31:20]};
        wire [31:0] tgt_b = i * 4 + imm_b;
        wire [31:0] tgt_j = i * 4 + imm_j;
        always @* begin
            if (w[6:0] == 7'b1100011) assume (tgt_b < CODE_TOP && tgt_b[1:0] == 2'b00);
            if (w[6:0] == 7'b1101111) assume (tgt_j < CODE_TOP && tgt_j[1:0] == 2'b00);
            if (w[6:0] == 7'b1100111) assume (w[19:15] == 5'd0 && imm_i < CODE_TOP && imm_i[1:0] == 2'b00);
            assume (w[6:0] != 7'b1110011);
        end
    end endgenerate

    always @* if (!reset) assert (imem_addr < MEM_SIZE);
endmodule
